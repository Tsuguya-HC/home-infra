#!/usr/bin/env bash
# Roll every Deployment / StatefulSet / DaemonSet in the cluster. Needed after the Kubernetes
# CA or the ServiceAccount signing key changes: clients read the CA and their token at
# start-up, and a controller that keeps running with stale credentials fails silently
# (ArgoCD kept reporting Synced for 1.5 h while every API call died with x509).
#
# Operator-managed pods (CloudNativePG) are not touched; their instance managers were not
# affected. Verification looks at effect, not at pod phase: ArgoCD's reconciledAt must move
# and the x509 error count in the controllers must be zero.
set -euo pipefail
cd "$(dirname "$0")/.."

started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}'); do
  n=$(kubectl -n "$ns" rollout restart deploy,sts,ds 2>/dev/null | grep -c restarted || true)
  [ "$n" -gt 0 ] && printf '%-20s %s restarted\n' "$ns" "$n"
done

echo "waiting for pods to settle..."
for _ in $(seq 1 60); do
  pending=$(kubectl get pods -A --no-headers | grep -vc 'Running\|Completed' || true)
  [ "$pending" -eq 0 ] && break
  sleep 10
done
echo "pods not Running/Completed: $pending"
kubectl get pods -A --no-headers | grep -v 'Running\|Completed' | awk '{print "  " $1, $2, $4}' | head -10 || true

echo "checks:"
newest=$(kubectl -n argocd get applications -o json | jq -r '[.items[].status.reconciledAt] | max')
[ "$newest" \> "$started" ] && echo "  argocd reconciledAt: fresh ($newest)" || echo "  argocd reconciledAt: STALE ($newest)"
for target in argocd/statefulset/argocd-application-controller external-secrets/deploy/external-secrets; do
  ns=${target%%/*}; obj=${target#*/}
  c=$(kubectl -n "$ns" logs "$obj" --since=2m 2>/dev/null | grep -c x509 || true)
  echo "  x509 in $target (2m): $c"
done
