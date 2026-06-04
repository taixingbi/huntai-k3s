#!/usr/bin/env bash
# Restore Argo CD AppProjects + all child Applications from Git (no argocd CLI required).
# Use after git pull when projects stay "default" or apps disappeared after huntai-apps prune.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

KUBECTL="${KUBECTL:-sudo k3s kubectl}"

echo "== git =="
git pull --ff-only

echo "== AppProjects =="
$KUBECTL apply -k argocd/projects/

echo "== child Applications (project + source paths from main) =="
$KUBECTL apply -k argocd/applications/

echo "== huntai-apps (app-of-apps) =="
$KUBECTL apply -f argocd/app-of-apps.yaml

echo "== hard refresh huntai-apps (reconcile from Git) =="
$KUBECTL annotate application huntai-apps -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite 2>/dev/null || true

echo ""
echo "== verify =="
$KUBECTL get appprojects -n argocd
$KUBECTL get applications -n argocd -o custom-columns=NAME:.metadata.name,PROJECT:.spec.project,SYNC:.status.sync.status --sort-by=.metadata.name

echo ""
echo "Next: Argo UI → Sync huntai-apps, then sync OutOfSync apps (or wait for auto-sync on dev)."
echo "Prod apps (gateway-api-prod, …) are manual sync. cloudflared-prod needs tunnel UUID + Secret."
