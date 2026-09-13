#!/bin/sh
# Render one machine config per node into clusterconfig/<host>.yaml.
#
#   talosctl gen config   cluster.yaml + secrets bundle + patches/all + patches/<role>
#                         -> role base configs (controlplane.yaml, worker.yaml)
#   machineconfig patch   role base + patches/node/<host>.yaml -> clusterconfig/<host>.yaml
#   talosctl validate     every rendered file
#
# POSIX sh on purpose: the same script runs on the workstation, in CI and inside the
# cluster's pxe-sync workflow (alpine, no bash). Needs talosctl and yq on PATH.
#
# The secrets bundle (`talosctl gen secrets` format) lives in 1Password, never in git.
#   TALOS_SECRETS=<path>          bypass 1Password (CI renders with a throwaway bundle:
#                                 the secrets don't change what validate checks)
#   TALOS_VALIDATE_ARGS="..."     validate flags, default --strict (warnings are errors).
#                                 A talosctl newer than cluster.yaml's talosVersion may
#                                 warn about fields the contract still uses; pass "" there.
set -eu
umask 077
cd "$(dirname "$0")/.."

name=$(yq -r .clusterName cluster.yaml)
endpoint=$(yq -r .endpoint cluster.yaml)
talos=$(yq -r .talosVersion cluster.yaml)
k8s=$(yq -r .kubernetesVersion cluster.yaml)
installer=$(yq -r .installer cluster.yaml)

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

secrets=${TALOS_SECRETS:-}
if [ -z "$secrets" ]; then
  op document get talos-secrets-bundle --vault home-cluster > "$tmp/secrets.yaml"
  secrets=$tmp/secrets.yaml
fi

set --
for f in patches/all/*.yaml; do set -- "$@" --config-patch "@$f"; done
for f in patches/controlplane/*.yaml; do set -- "$@" --config-patch-control-plane "@$f"; done
for f in patches/worker/*.yaml; do set -- "$@" --config-patch-worker "@$f"; done

# --install-disk "" drops the /dev/sda default so each node patch decides between
# `disk` and `diskSelector`.
talosctl gen config "$name" "$endpoint" \
  --with-secrets "$secrets" \
  --talos-version "$talos" \
  --kubernetes-version "$k8s" \
  --install-image "$installer:$talos" \
  --install-disk "" \
  --with-docs=false --with-examples=false \
  --output-types controlplane,worker \
  --output "$tmp/base" --force \
  "$@" > /dev/null

mkdir -p clusterconfig
yq -r '.nodes[] | .host + " " + .role' nodes.yaml > "$tmp/nodes"
while read -r host role; do
  talosctl machineconfig patch "$tmp/base/$role.yaml" \
    -p "@patches/node/$host.yaml" \
    -o "clusterconfig/$host.yaml"
  # shellcheck disable=SC2086 # TALOS_VALIDATE_ARGS is a flag list by design
  talosctl validate -c "clusterconfig/$host.yaml" -m metal ${TALOS_VALIDATE_ARGS---strict}
done < "$tmp/nodes"
