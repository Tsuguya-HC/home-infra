#!/usr/bin/env bash
# Rebuild the secrets bundle from a live control plane's applied machine config and compare
# it with the copy in 1Password. The cluster is the source of truth: after anything that
# rotates secrets on the nodes directly (talosctl rotate-ca), this brings 1Password back in
# line so `make genconfig` renders what the nodes actually run.
#
#   secrets-sync.sh          compare only (per-key same/DIFF, no values)
#   secrets-sync.sh --push   also replace the 1Password document when something differs
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
. scripts/lib.sh

push=false
[ "${1:-}" = "--push" ] && push=true

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cp=$(first_cp)
talosctl -n "$cp" get machineconfig v1alpha1 -o jsonpath='{.spec}' > "$tmp/live.yaml"
talosctl gen secrets --from-controlplane-config "$tmp/live.yaml" -o "$tmp/rebuilt.yaml" > /dev/null 2>&1
op document get "$BUNDLE_ITEM" --vault "$BUNDLE_VAULT" > "$tmp/op.yaml"

echo "bundle rebuilt from $cp vs 1Password:"
if bundle_diff "$tmp/rebuilt.yaml" "$tmp/op.yaml"; then
  echo "in sync"
  exit 0
fi

if [ "$push" != true ]; then
  echo "out of sync; re-run with --push to update 1Password from the cluster"
  exit 1
fi

op document edit "$BUNDLE_ITEM" "$tmp/rebuilt.yaml" --vault "$BUNDLE_VAULT" --file-name secrets.yaml > /dev/null
echo "1Password document updated from the cluster"
