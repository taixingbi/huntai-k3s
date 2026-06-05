#!/usr/bin/env bash
# Apply web prod overlay (after layer-web-v1 push to main).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

KUBECTL="${KUBECTL:-sudo k3s kubectl}"

echo "== git =="
git pull --ff-only origin main

echo "== kustomize =="
$KUBECTL kustomize manifests/web/overlays/prod >/dev/null

echo "== Argo CD web-prod =="
$KUBECTL apply -f argocd/applications/web-prod.yaml
$KUBECTL annotate application web-prod -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite 2>/dev/null || true

echo "== apply prod manifests (Argo is manual-sync) =="
$KUBECTL apply -k manifests/web/overlays/prod/

echo ""
echo "Waiting for rollout (up to 180s)..."
$KUBECTL -n ai-prod rollout status deployment/layer-web --timeout=180s 2>/dev/null || true
echo ""
$KUBECTL get application web-prod -n argocd \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status 2>/dev/null || true
$KUBECTL -n ai-prod get deploy,pods -l app=layer-web 2>/dev/null || true
