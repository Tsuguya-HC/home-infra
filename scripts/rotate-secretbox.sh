#!/usr/bin/env bash
# Rotate the etcd encryption key (secretbox) without losing access to existing Secrets.
# Talos 1.14 renders KubeEtcdEncryptionConfig from the bundle's
# secrets.secretboxencryptionsecret as a single key named `key2`. kube-apiserver tries the
# listed keys in order for reads and encrypts with the first, so the rotation is the usual
# Kubernetes two-key dance, done twice because the key that survives has to be `key2` again
# (the name is part of the ciphertext prefix, and only the bundle value is in git-managed
# rendering):
#
#   rotate-secretbox.sh 1   keys [key2=old, key3=new]  every apiserver can read both
#   rotate-secretbox.sh 2   keys [key3=new, key2=old]  new writes use the new key; every
#                                                       Secret is rewritten
#   rotate-secretbox.sh 3   bundle := new; keys [key2=new, key3=new]; every Secret is
#                                                       rewritten again, now under key2
#   rotate-secretbox.sh 4   plain render (key2=new)     key3 gone
#
# One step per invocation so a step fits a terminal session; the pending key lives in a
# private state file between steps and is removed at the end. Each step applies to the
# control planes one at a time (the apiserver restarts) and waits for readiness. The
# interim key lists carry secrets, so they go to the nodes as `apply-config --config-patch`
# files from a private temp dir on top of the rendered config.
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
. scripts/lib.sh

step=${1:?step 1-4}
state=$HOME/.config/home-infra/secretbox-rotation
mkdir -p "$(dirname "$state")"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Strategic merge appends to the `resources` list instead of replacing it, and
# kube-apiserver uses the first entry for a resource, so the rendered document is deleted
# and re-added rather than merged into.
# shellcheck disable=SC2016 # $patch is literal YAML, not a shell variable
printf 'apiVersion: v1alpha1\nkind: KubeEtcdEncryptionConfig\n$patch: delete\n' > "$tmp/delete.yaml"

# $@ = ordered "name=secret" pairs; same shape as the rendered document (no identity
# provider: everything in etcd is encrypted already)
write_patch() {
  {
    echo 'apiVersion: v1alpha1'
    echo 'kind: KubeEtcdEncryptionConfig'
    echo 'config:'
    echo '  resources:'
    echo '    - resources: [secrets]'
    echo '      providers:'
    echo '        - secretbox:'
    echo '            keys:'
    for kv in "$@"; do
      echo "              - name: ${kv%%=*}"
      echo "                secret: ${kv#*=}"
    done
  } > "$tmp/patch.yaml"
}

apply_cps() { # applies the rendered config (+ patch if present) to each control plane
  for host in $(yq -r '.nodes[] | select(.role == "controlplane") | .host' nodes.yaml); do
    ip=$(yq -r ".nodes[] | select(.host == \"$host\") | .ip" nodes.yaml)
    if [ -s "$tmp/patch.yaml" ]; then
      talosctl -n "$ip" apply-config -f "clusterconfig/$host.yaml" -p "@$tmp/delete.yaml" -p "@$tmp/patch.yaml" > /dev/null 2>&1
    else
      talosctl -n "$ip" apply-config -f "clusterconfig/$host.yaml" > /dev/null 2>&1
    fi
    sleep 20
    for _ in $(seq 1 30); do [ "$(kubectl get --raw /readyz --server "https://$ip:6443" 2>/dev/null)" = ok ] && break; sleep 5; done
    echo "  $host: apiserver $(kubectl get --raw /readyz --server "https://$ip:6443" 2>/dev/null || echo 'not ready')"
  done
}

rewrite_secrets() {
  # Rewriting stores every Secret under the first key. One at a time with retries:
  # controllers keep updating some Secrets, and a replace races them into a Conflict.
  # Immutable Secrets cannot be replaced; they stay readable through the old key until
  # their owners recreate them.
  local n=0 failed=0 ns name attempt
  while IFS=/ read -r ns name; do
    for attempt in 1 2 3 4 5; do
      if kubectl -n "$ns" get secret "$name" -o json 2>/dev/null | kubectl replace -f - > /dev/null 2>&1; then
        n=$((n+1)); break
      fi
      [ "$attempt" = 5 ] && { failed=$((failed+1)); echo "  could not rewrite $ns/$name" >&2; }
      sleep 1
    done
  done < <(kubectl get secrets -A -o json | jq -r '.items[] | select(.immutable != true) | .metadata.namespace + "/" + .metadata.name')
  echo "  secrets rewritten: $n, failed: $failed"
  [ "$failed" -eq 0 ]
}

current_keys() { # what the rendered config would carry now, names only
  yq -N 'select(.kind=="KubeEtcdEncryptionConfig") | [.config.resources[0].providers[0].secretbox.keys[].name] | join(",")' "clusterconfig/$(first_cp_host).yaml" | grep -v '^$'

}
first_cp_host() { yq -r '[.nodes[] | select(.role == "controlplane") | .host][0]' nodes.yaml; }

make -s genconfig > /dev/null 2>&1

case "$step" in
  1)
    op document get "$BUNDLE_ITEM" --vault "$BUNDLE_VAULT" > "$tmp/bundle.yaml"
    old=$(yq -r '.secrets.secretboxencryptionsecret' "$tmp/bundle.yaml")
    talosctl gen secrets -o "$tmp/fresh.yaml" > /dev/null 2>&1
    new=$(yq -r '.secrets.secretboxencryptionsecret' "$tmp/fresh.yaml")
    [ -n "$old" ] && [ -n "$new" ] && [ "$old" != "$new" ] || { echo "could not derive keys" >&2; exit 1; }
    printf 'old: %s\nnew: %s\n' "$old" "$new" > "$state"
    echo "step 1: accept the new key alongside the old one"
    write_patch "key2=$old" "key3=$new"; apply_cps
    ;;
  2)
    old=$(yq -r .old "$state"); new=$(yq -r .new "$state")
    echo "step 2: encrypt with the new key, rewrite every Secret"
    write_patch "key3=$new" "key2=$old"; apply_cps; rewrite_secrets
    ;;
  3)
    new=$(yq -r .new "$state")
    echo "step 3: bundle takes the new key as key2, rewrite every Secret under it"
    op document get "$BUNDLE_ITEM" --vault "$BUNDLE_VAULT" > "$tmp/bundle.yaml"
    yq -i ".secrets.secretboxencryptionsecret = \"$new\"" "$tmp/bundle.yaml"
    op document edit "$BUNDLE_ITEM" "$tmp/bundle.yaml" --vault "$BUNDLE_VAULT" --file-name secrets.yaml > /dev/null
    make -s genconfig > /dev/null 2>&1
    [ "$(current_keys)" = key2 ] || { echo "rendered keys unexpected: $(current_keys)" >&2; exit 1; }
    write_patch "key2=$new" "key3=$new"; apply_cps; rewrite_secrets
    ;;
  4)
    echo "step 4: plain render, key3 gone"
    rm -f "$tmp/patch.yaml"; apply_cps
    rm -f "$state"
    echo "done: $(kubectl get secrets -A --no-headers | wc -l) secrets readable, rendered keys: $(current_keys)"
    ;;
  *) echo "usage: $0 1|2|3|4" >&2; exit 2 ;;
esac
