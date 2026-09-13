#!/usr/bin/env bash
# Rotate the Kubernetes API CA or the Talos API CA with `talosctl rotate-ca` (graceful,
# three phases across all nodes), then make everything that depends on the CA follow:
#
#   kubernetes   ~/.kube/config is re-issued; every in-cluster client that read the old CA
#                at start-up keeps failing until restarted -> run restart-workloads.sh
#   talos        the new talosconfig is installed locally, stored in 1Password (Document
#                `talos-admin-talosconfig`) and the in-cluster ExternalSecret is
#                force-refreshed so etcd-backup / upgrade-k8s / node-shutdown keep working
#
# Both end with secrets-sync.sh --push so the bundle matches the nodes again.
#
#   rotate-ca.sh kubernetes|talos           dry run (talosctl's own), nothing changes
#   rotate-ca.sh kubernetes|talos --apply   rotate
#
# The talosctl output is written to a private temp file and only progress lines (no long
# tokens) are echoed: the tool prints the new CA, key included, on stdout.
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
. scripts/lib.sh

which=${1:?kubernetes|talos}
apply=false
[ "${2:-}" = "--apply" ] && apply=true
case "$which" in
  kubernetes) flags="--talos=false --kubernetes=true" ;;
  talos)      flags="--talos=true --kubernetes=false" ;;
  *) echo "usage: $0 kubernetes|talos [--apply]" >&2; exit 2 ;;
esac

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

dry=true
[ "$apply" = true ] && dry=false

rc=0
# shellcheck disable=SC2086 # flags is a deliberate word list
talosctl rotate-ca $flags \
    --dry-run="$dry" \
    --control-plane-nodes "$(cp_ips)" \
    --worker-nodes "$(worker_ips)" \
    --with-docs=false --with-examples=false \
    -o "$tmp/talosconfig" > "$tmp/log" 2>&1 || rc=$?
safe_lines < "$tmp/log"

# talosctl writes the new talosconfig before it re-creates its own client; if that last
# step fails the CA is already rotated and the file is the only way back in. Install it
# whenever it exists, before looking at the exit status. (The dry run of the Talos
# rotation always ends with "failed to determine endpoints": it returns no config to
# rebuild the client from. That is not a failure of the dry run.)
if [ "$which" = talos ] && [ -s "$tmp/talosconfig" ]; then
  IFS=, read -r -a cps <<< "$(cp_ips)"
  IFS=, read -r -a wks <<< "$(worker_ips)"
  ctx=$(yq -r '.context' "$tmp/talosconfig")
  # merge renames an incoming context that already exists ("home-cluster-1"), so drop the
  # old one first; the old CA is gone from the nodes anyway.
  talosctl config remove "$ctx" -y > /dev/null 2>&1 || true
  talosctl config merge "$tmp/talosconfig" > /dev/null
  talosctl config context "$ctx" > /dev/null
  talosctl config endpoint "${cps[@]}" > /dev/null
  talosctl config node "${cps[@]}" "${wks[@]}" > /dev/null
  echo "talosconfig installed locally (context $ctx)"
fi

if [ "$rc" -ne 0 ]; then
  if [ "$apply" != true ] && grep -q 'Dry-run mode enabled' "$tmp/log"; then
    exit 0
  fi
  echo "rotate-ca exited with $rc" >&2
  exit "$rc"
fi

[ "$apply" = true ] || exit 0

case "$which" in
  kubernetes)
    talosctl -n "$(first_cp)" kubeconfig -f --force-context-name admin@home-cluster ~/.kube/config > /dev/null
    echo "kubeconfig re-issued"
    ;;
  talos)
    op document edit "$TALOSCONFIG_ITEM" ~/.talos/config --vault "$BUNDLE_VAULT" --file-name talosconfig > /dev/null
    echo "talosconfig stored in 1Password"
    kubectl -n argo annotate externalsecret talosconfig "force-sync=$(date +%s)" --overwrite > /dev/null
    echo "in-cluster talosconfig refresh requested"
    ;;
esac

bash scripts/secrets-sync.sh --push
