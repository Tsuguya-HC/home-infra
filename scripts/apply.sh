#!/usr/bin/env bash
# Apply clusterconfig/<host>.yaml to every node in nodes.yaml. Extra arguments go to
# `talosctl apply-config` (e.g. --dry-run, --mode=staged).
set -euo pipefail
cd "$(dirname "$0")/.."

while IFS=$'\t' read -r host ip; do
  echo "===> $host ($ip)"
  talosctl -n "$ip" apply-config -f "clusterconfig/$host.yaml" "$@"
done < <(yq -r '.nodes[] | [.host, .ip] | @tsv' nodes.yaml)
