#!/usr/bin/env bash
# Apply orchestrator prod overlay (after layer-orchestrator-v1 push to main).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

KUBECTL="${KUBECTL:-sudo k3s kubectl}"

echo "== git =="
git pull --ff-only origin main

echo "== kustomize =="
$KUBECTL kustomize manifests/orchestrator/overlays/prod >/dev/null

if ! $KUBECTL -n ai-prod get secret layer-ai-prod-secrets >/dev/null 2>&1; then
  echo "error: secret layer-ai-prod-secrets missing in ai-prod (docs/deploy-prod.md)"
  exit 1
fi

echo "== Argo CD orchestrator-prod =="
$KUBECTL apply -f argocd/applications/orchestrator-prod.yaml
$KUBECTL annotate application orchestrator-prod -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite 2>/dev/null || true

echo "== apply prod manifests (Argo is manual-sync) =="
$KUBECTL apply -k manifests/orchestrator/overlays/prod/

echo ""
echo "Waiting for rollout (up to 120s)..."
$KUBECTL -n ai-prod rollout status deployment/layer-orchestrator --timeout=120s 2>/dev/null || true
echo ""
$KUBECTL get application orchestrator-prod -n argocd \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status 2>/dev/null || true
$KUBECTL -n ai-prod get deploy,pods -l app=layer-orchestrator 2>/dev/null || true
