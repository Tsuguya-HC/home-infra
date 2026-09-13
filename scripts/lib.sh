#!/usr/bin/env bash
# Shared helpers for the secrets-rotation scripts. Sourced, not executed.

# Print only lines whose every whitespace-separated token is 40 characters or shorter.
# Certificates, keys and tokens are longer than that; progress lines are not. This is a
# guard for logs that may carry secret material, not a substitute for keeping them out.
safe_lines() {
  awk '{ ok = 1; for (i = 1; i <= NF; i++) if (length($i) > 40) ok = 0; if (ok) print; else print "(line withheld)" }'
}

cp_ips()     { yq -r '[.nodes[] | select(.role == "controlplane") | .ip] | join(",")' nodes.yaml; }
worker_ips() { yq -r '[.nodes[] | select(.role == "worker") | .ip] | join(",")' nodes.yaml; }
first_cp()   { yq -r '[.nodes[] | select(.role == "controlplane") | .ip][0]' nodes.yaml; }

# shellcheck disable=SC2034 # used by the scripts that source this file
BUNDLE_ITEM=talos-secrets-bundle
# shellcheck disable=SC2034
BUNDLE_VAULT=home-cluster
# A Document created by the service account: the older `talosconfig` Secure Note was
# created by a user and the service account gets 404 on every edit of it.
# shellcheck disable=SC2034
TALOSCONFIG_ITEM=talos-admin-talosconfig

# The keys of a `talosctl gen secrets` bundle, in the order the docs describe them.
BUNDLE_KEYS="cluster.id cluster.secret secrets.bootstraptoken secrets.secretboxencryptionsecret trustdinfo.token certs.etcd.crt certs.etcd.key certs.k8s.crt certs.k8s.key certs.k8saggregator.crt certs.k8saggregator.key certs.k8sserviceaccount.key certs.os.crt certs.os.key"

# Compare two bundles key by key. Prints "<key> same|DIFF" lines, never values.
# Returns 1 if any key differs.
bundle_diff() {
  local a=$1 b=$2 k ha hb rc=0
  for k in $BUNDLE_KEYS; do
    ha=$(yq -r ".$k // \"\"" "$a" | tr -d '\n' | sha256sum | cut -c1-8)
    hb=$(yq -r ".$k // \"\"" "$b" | tr -d '\n' | sha256sum | cut -c1-8)
    if [ "$ha" = "$hb" ]; then printf '  %-36s same\n' "$k"; else printf '  %-36s DIFF\n' "$k"; rc=1; fi
  done
  return $rc
}
