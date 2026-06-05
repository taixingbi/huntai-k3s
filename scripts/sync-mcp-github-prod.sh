#!/usr/bin/env bash
# Apply mcp-github prod overlay (after layer-mcp-github-v1 push to main).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

KUBECTL="${KUBECTL:-sudo k3s kubectl}"

echo "== git =="
git pull --ff-only origin main

echo "== kustomize =="
$KUBECTL kustomize manifests/tool/overlays/prod >/dev/null

if ! $KUBECTL -n ai-prod get secret layer-mcp-github-v1-secrets >/dev/null 2>&1; then
  echo "error: secret layer-mcp-github-v1-secrets missing in ai-prod (docs/deploy-mcp-github.md)"
  exit 1
fi

echo "== Argo CD mcp-github-prod =="
$KUBECTL apply -f argocd/applications/mcp-github-prod.yaml
$KUBECTL annotate application mcp-github-prod -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite 2>/dev/null || true

echo "== remove legacy layer-mcp-github-v1 (rename cutover) =="
$KUBECTL -n ai-prod delete deployment,service layer-mcp-github-v1 --ignore-not-found --wait=true

echo "== apply prod manifests (Argo is manual-sync) =="
$KUBECTL apply -k manifests/tool/overlays/prod/

echo ""
echo "Waiting for rollout (up to 120s)..."
$KUBECTL -n ai-prod rollout status deployment/layer-mcp-github --timeout=120s 2>/dev/null || true
echo ""
$KUBECTL get application mcp-github-prod -n argocd \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status 2>/dev/null || true
$KUBECTL -n ai-prod get deploy,pods -l app=layer-mcp-github 2>/dev/null || true
