#!/usr/bin/env bash
# Apply gateway-api prod overlay (after layer-gateway-api-v1 push to main).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

KUBECTL="${KUBECTL:-sudo k3s kubectl}"

echo "== git =="
git pull --ff-only origin main

echo "== kustomize =="
$KUBECTL kustomize manifests/gateway-api/overlays/prod >/dev/null

if ! $KUBECTL -n ai-prod get secret layer-ai-prod-secrets >/dev/null 2>&1; then
  echo "error: secret layer-ai-prod-secrets missing in ai-prod (docs/deploy-prod.md)"
  exit 1
fi

echo "== Argo CD gateway-api-prod =="
$KUBECTL apply -f argocd/applications/gateway-api-prod.yaml
$KUBECTL annotate application gateway-api-prod -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite 2>/dev/null || true

echo "== apply prod manifests (Argo is manual-sync) =="
$KUBECTL apply -k manifests/gateway-api/overlays/prod/

echo ""
echo "Waiting for rollout (up to 120s)..."
$KUBECTL -n ai-prod rollout status deployment/layer-gateway-api --timeout=120s 2>/dev/null || true
echo ""
$KUBECTL get application gateway-api-prod -n argocd \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status 2>/dev/null || true
$KUBECTL -n ai-prod get deploy,pods -l app=layer-gateway-api 2>/dev/null || true
