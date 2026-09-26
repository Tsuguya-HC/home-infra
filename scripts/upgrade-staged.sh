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

# Optional short host names limit the rollout (e.g. `upgrade-staged.sh cp-11`), so a
# rollout can be driven one node per invocation and resumed.
if [ $# -gt 0 ]; then
  ips=$(for n in "$@"; do yq -r ".nodes[] | select((.host | split(\".\") | .[0]) == \"$n\") | .ip" nodes.yaml; done)
else
  ips=$(yq -r '.nodes[].ip' nodes.yaml)
fi

for ip in $ips; do
  node="$(kubectl get node -o json | jq -r --arg ip "$ip" '.items[] | select(.status.addresses[]?.address==$ip) | .metadata.name')"
  echo "===> $node ($ip)"

  echo "  staging upgrade…"
  # --no-reboot: install the new image without rebooting or draining. The default path
  # cordons and evicts first, which PDBs on node-pinned StatefulSets block forever.
  # (--stage is the deprecated legacy spelling of the same thing.)
  talosctl upgrade \
    --nodes="$ip" \
    --image="$INSTALLER_IMAGE" \
    --no-reboot

  # Cordon without evicting. Otherwise controllers keep placing pods on the node while
  # it shuts down, and each one is rejected and left behind as a Failed pod.
  echo "  cordoning…"
  kubectl cordon "$node"
  # Don't leave the node cordoned if reboot or the Ready wait below fails.
  trap 'kubectl uncordon "$node" || echo "  WARNING: $node is still cordoned; uncordon it by hand" >&2' EXIT

  echo "  rebooting…"
  talosctl reboot --nodes="$ip"

  echo "  waiting for Ready…"
  kubectl wait --for=condition=Ready "node/$node" --timeout=10m

  echo "  uncordoning…"
  kubectl uncordon "$node"
  trap - EXIT
  echo
done

echo "All nodes upgraded to $INSTALLER_IMAGE."
