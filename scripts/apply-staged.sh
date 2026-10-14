#!/usr/bin/env bash
# Apply clusterconfig/<host>.yaml with --mode=staged and reboot the nodes one at a time,
# control planes first, waiting for each to be Ready again. For changes Talos cannot apply
# live (machine.token, some install fields). Never reboots two nodes at once.
#
#   apply-staged.sh                 all nodes in nodes.yaml order (control planes first)
#   apply-staged.sh cp-11 wn-03     only these (short host names)
#
# A control plane is not left until its etcd sees a leader again. ETCD_ISOLATED=<short host>
# skips that wait for one node: the first control plane of an etcd CA rotation stays cut off
# from the others until the second one is back (rotate-bundle.sh sets it).
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
  boot_id() { talosctl -e "$ip" -n "$ip" read /proc/sys/kernel/random/boot_id 2>/dev/null || true; }
  before=$(boot_id)
  [ -n "$before" ] || { echo "  cannot read the boot id of $node" >&2; exit 1; }
  echo "  staging..."
  # The node itself is the endpoint: the VIP moves (or is gone) while control planes reboot.
  talosctl -e "$ip" -n "$ip" apply-config --mode=staged -f "clusterconfig/$host.yaml" 2>&1 | status_lines | sed 's/^/  /'
  echo "  rebooting..."
  # --wait (the default) blocks until the boot sequence completes, which never happens on
  # the first control plane of an etcd CA rotation: it sat out the full 30m timeout
  # (2026-10-14). A new boot id says the node went down; readiness is polled below.
  talosctl -e "$ip" -n "$ip" reboot --wait=false > /dev/null 2>&1 || { echo "  reboot request failed on $node" >&2; exit 1; }
  now=
  for _ in $(seq 1 60); do
    sleep 10
    now=$(boot_id)
    [ -n "$now" ] && [ "$now" != "$before" ] && break
    now=
  done
  [ -n "$now" ] || { echo "  $node did not come back with a new boot id after 10 minutes" >&2; exit 1; }
  # Polled rather than `kubectl wait`: the API may be unreachable for a while when a
  # control plane is down, and one failed request must not abort the rollout. Ready stays
  # True from before the reboot for up to node-monitor-grace-period (50s), hence the boot id.
  ready=
  for _ in $(seq 1 60); do
    [ "$(kubectl get node "$node" -o jsonpath='{.status.nodeInfo.bootID} {.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "$now True" ] && { ready=1; break; }
    sleep 10
  done
  [ -n "$ready" ] || { echo "  $node not Ready after 10 minutes" >&2; exit 1; }
  # `service etcd` reports HEALTH OK even while the member is cut off from the others; a
  # leader id in `etcd status` is what says it rejoined. Only the member and leader ids
  # (the 16-hex fields) are taken from the output.
  if [ "$(yq -r ".nodes[] | select(.host == \"$host\") | .role" nodes.yaml)" = controlplane ] && [ "$node" != "${ETCD_ISOLATED:-}" ]; then
    joined=
    for _ in $(seq 1 60); do
      leader=$(talosctl -e "$ip" -n "$ip" etcd status 2>/dev/null | sed -n 2p | grep -oE '\b[0-9a-f]{16}\b' | sed -n 2p || true)
      [ -n "$leader" ] && [ "$leader" != 0000000000000000 ] && { joined=1; break; }
      sleep 10
    done
    [ -n "$joined" ] || { echo "  etcd on $node has no leader after 10 minutes" >&2; exit 1; }
  fi
  for _ in $(seq 1 30); do talosctl -e "$ip" -n "$ip" version --short > /dev/null 2>&1 && break; sleep 5; done
  echo "  Ready"
done
