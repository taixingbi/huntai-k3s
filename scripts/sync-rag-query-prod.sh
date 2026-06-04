#!/usr/bin/env bash
# Apply rag-query prod overlay and refresh Argo CD (after layer-rag-query-v1 push to main).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

KUBECTL="${KUBECTL:-sudo k3s kubectl}"

echo "== git =="
git pull --ff-only origin main

echo "== kustomize =="
$KUBECTL kustomize manifests/rag/overlays/prod >/dev/null

echo "== Argo CD rag-query-prod (auto-sync after apply) =="
$KUBECTL apply -f argocd/applications/rag-query-prod.yaml
$KUBECTL annotate application rag-query-prod -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite 2>/dev/null || true

echo "== apply prod manifests (immediate rollout if Argo sync is delayed) =="
$KUBECTL apply -k manifests/rag/overlays/prod/

echo ""
echo "Waiting for rollout (up to 120s)..."
$KUBECTL -n ai-prod rollout status deployment/layer-rag-query --timeout=120s 2>/dev/null || true
echo ""
$KUBECTL get application rag-query-prod -n argocd \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status 2>/dev/null || true
$KUBECTL -n ai-prod get deploy,pods -l app=layer-rag-query 2>/dev/null || true
