#!/usr/bin/env bash
# Replace secrets that live only in the bundle (not rotated by talosctl rotate-ca): generate
# a fresh bundle, splice the requested keys into the current one, store it in 1Password,
# stage the re-rendered machine configs on every node and reboot the nodes one at a time.
#
#   rotate-bundle.sh trustdinfo.token secrets.bootstraptoken cluster.id cluster.secret \
#                    certs.k8saggregator certs.k8sserviceaccount
#
# Talos cannot apply a `machine.token` change without a reboot, and `apply-config` in its
# default mode reboots the node by itself. Applying that to six nodes in a loop rebooted
# the whole cluster at once (2026-09-13), so this script always stages (`--mode=staged`)
# and then reboots control planes first, one node at a time, waiting for Ready.
#
# What each one costs (Talos 1.13, no staged rotation for these):
#   trustdinfo.token / secrets.bootstraptoken   nothing running notices; new nodes use the new
#                                               token (reboot needed to apply)
#   cluster.id / cluster.secret                 discovery re-registers, `talosctl get members`
#                                               is incomplete for up to 30 min
#   certs.k8saggregator                         kube-apiserver restarts; aggregated APIs
#                                               (metrics-server) blip until all 3 agree
#   certs.k8sserviceaccount                     every ServiceAccount token becomes invalid:
#                                               run restart-workloads.sh right after
#   secrets.secretboxencryptionsecret           refused: needs the two-key dance, see
#                                               rotate-secretbox.sh
#   certs.etcd                                  no graceful path upstream (#8808). etcd reloads
#                                               its leaf certificates from disk but keeps the
#                                               CA pool it started with, so a live apply leaves
#                                               every member rejecting its peers and every
#                                               kube-apiserver unable to open new etcd
#                                               connections (2026-09-13). Staged + reboot,
#                                               control planes only: the rebooted member is
#                                               alone until the second one follows, and the
#                                               API is away while the second one reboots
#
# talosctl prints the config diff (secrets included) on stderr when it applies. Nothing
# from talosctl reaches the terminal except a short allowlist of status lines.
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
. scripts/lib.sh

[ $# -ge 1 ] || { echo "usage: $0 <bundle key>..." >&2; exit 2; }
etcd=false
for k in "$@"; do
  case "$k" in
    trustdinfo.token|secrets.bootstraptoken|cluster.id|cluster.secret|certs.k8saggregator|certs.k8sserviceaccount) ;;
    secrets.secretboxencryptionsecret)
      echo "refusing: $k needs rotate-secretbox.sh" >&2; exit 2 ;;
    certs.etcd) etcd=true ;;
    certs.k8s|certs.os)
      echo "refusing: $k is a CA; use rotate-ca.sh" >&2; exit 2 ;;
    *) echo "unknown bundle key: $k" >&2; exit 2 ;;
  esac
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

op document get "$BUNDLE_ITEM" --vault "$BUNDLE_VAULT" > "$tmp/current.yaml"
talosctl gen secrets -o "$tmp/fresh.yaml" > /dev/null 2>&1
cp "$tmp/current.yaml" "$tmp/next.yaml"
for k in "$@"; do
  yq -i ".$k = load(\"$tmp/fresh.yaml\").$k" "$tmp/next.yaml"
done

echo "keys that change:"
bundle_diff "$tmp/current.yaml" "$tmp/next.yaml" | grep DIFF || true

op document edit "$BUNDLE_ITEM" "$tmp/next.yaml" --vault "$BUNDLE_VAULT" --file-name secrets.yaml > /dev/null
echo "1Password document updated"

make -s genconfig > /dev/null 2>&1
echo "machine configs rendered"

if [ "$etcd" = true ] && [ $# -eq 1 ]; then
  # Worker configs do not carry cluster.etcd.ca; no reason to reboot them.
  # shellcheck disable=SC2046 # host names, no spaces
  bash scripts/apply-staged.sh $(yq -r '.nodes[] | select(.role == "controlplane") | .host | split(".") | .[0]' nodes.yaml)
else
  bash scripts/apply-staged.sh
fi

case " $* " in
  *" certs.k8sserviceaccount "*)
    echo
    echo "ServiceAccount signing key changed: run scripts/restart-workloads.sh now." ;;
esac
