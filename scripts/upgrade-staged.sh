#!/usr/bin/env bash
# Roll out a Talos upgrade one node at a time, bypassing eviction-based drain.
# Necessary while node-pinned StatefulSets and Trident v1.6.0 attach panic make
# graceful drain unsafe (see incidents.md 2026-05-04).
set -euo pipefail

cd "$(dirname "$0")/.."

TALOS_VERSION="$(yq -r .talosVersion cluster.yaml)"
INSTALLER_IMAGE="${INSTALLER_IMAGE:-$(yq -r .installer cluster.yaml):${TALOS_VERSION}}"

echo "Image: $INSTALLER_IMAGE"
echo

for ip in $(yq -r '.nodes[].ip' nodes.yaml); do
  node="$(kubectl get node -o json | jq -r --arg ip "$ip" '.items[] | select(.status.addresses[]?.address==$ip) | .metadata.name')"
  echo "===> $node ($ip)"

  echo "  staging upgrade…"
  talosctl upgrade \
    --nodes="$ip" \
    --image="$INSTALLER_IMAGE" \
    --stage

  echo "  rebooting…"
  talosctl reboot --nodes="$ip"

  echo "  waiting for Ready…"
  kubectl wait --for=condition=Ready "node/$node" --timeout=10m

  if [ "$(kubectl get node "$node" -o jsonpath='{.spec.unschedulable}')" = "true" ]; then
    echo "  uncordoning…"
    kubectl uncordon "$node"
  fi
  echo
done

echo "All nodes upgraded to $INSTALLER_IMAGE."
