#!/usr/bin/env bash
# Apply clusterconfig/<host>.yaml with --mode=staged and reboot the nodes one at a time,
# control planes first, waiting for each to be Ready again. For changes Talos cannot apply
# live (machine.token, some install fields). Never reboots two nodes at once.
#
#   apply-staged.sh                 all nodes in nodes.yaml order (control planes first)
#   apply-staged.sh cp-11 wn-03     only these (short host names)
#
# Only status lines from talosctl are shown; its config diff (secrets included) is dropped.
set -euo pipefail
cd "$(dirname "$0")/.."

status_lines() { grep -E '^(Applied configuration|No changes|.*error)' || true; }

if [ $# -gt 0 ]; then
  hosts=$(for n in "$@"; do yq -r ".nodes[] | select((.host | split(\".\") | .[0]) == \"$n\") | .host" nodes.yaml; done)
else
  hosts=$(yq -r '(.nodes[] | select(.role == "controlplane") | .host), (.nodes[] | select(.role == "worker") | .host)' nodes.yaml)
fi

for host in $hosts; do
  ip=$(yq -r ".nodes[] | select(.host == \"$host\") | .ip" nodes.yaml)
  node=${host%%.*}
  echo "===> $host ($ip)"
  echo "  staging..."
  # The node itself is the endpoint: the VIP moves (or is gone) while control planes reboot.
  talosctl -e "$ip" -n "$ip" apply-config --mode=staged -f "clusterconfig/$host.yaml" 2>&1 | status_lines | sed 's/^/  /'
  echo "  rebooting..."
  talosctl -e "$ip" -n "$ip" reboot > /dev/null 2>&1
  sleep 20
  # Polled rather than `kubectl wait`: the API may be unreachable for a while when a
  # control plane is down, and one failed request must not abort the rollout.
  ready=
  for _ in $(seq 1 60); do
    [ "$(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ] && { ready=1; break; }
    sleep 10
  done
  [ -n "$ready" ] || { echo "  $node not Ready after 10 minutes" >&2; exit 1; }
  for _ in $(seq 1 30); do talosctl -e "$ip" -n "$ip" version --short > /dev/null 2>&1 && break; sleep 5; done
  echo "  Ready"
done
