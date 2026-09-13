#!/bin/bash
# Copy rendered machine configs to pxe/config/<mac>.yaml for nodes that have a `mac`
# in nodes.yaml (iPXE fetches the config by the booting NIC's MAC, hexhyp format).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="${SCRIPT_DIR}/../.."
CONFIG_DIR="${SCRIPT_DIR}/../config"

mkdir -p "$CONFIG_DIR"

while IFS=$'\t' read -r host mac; do
  if [[ -z "$mac" ]]; then
    echo "skip: $host has no mac in nodes.yaml" >&2
    continue
  fi
  src="${REPO_DIR}/clusterconfig/${host}.yaml"
  dst="${CONFIG_DIR}/${mac}.yaml"
  if [[ -f "$src" ]]; then
    cp "$src" "$dst"
    echo "Synced: ${host} → ${mac}.yaml"
  else
    echo "WARNING: $src not found" >&2
  fi
done < <(yq -r '.nodes[] | [.host, .mac // ""] | @tsv' "${REPO_DIR}/nodes.yaml")
