#!/usr/bin/env bash
# Bootstrap prod user stack (ai-prod): validate manifests, register Argo apps, print sync order.
# Does not create secrets or sync Argo apps automatically — see docs/deploy-prod.md.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

KUBECTL="${KUBECTL:-sudo k3s kubectl}"
ARGOCD="${ARGOCD:-argocd}"

echo "== kustomize (prod overlays) =="
for p in \
  manifests/gateway-api/overlays/prod \
  manifests/orchestrator/overlays/prod \
  manifests/rag/overlays/prod \
  manifests/tool/overlays/prod \
  manifests/web/overlays/prod \
  manifests/ingress/overlays/prod
do
  echo "  $p"
  $KUBECTL kustomize "$p" >/dev/null
done

if ! $KUBECTL get namespace ai-prod >/dev/null 2>&1; then
  echo "namespace ai-prod will be created on first Argo sync"
fi

if ! $KUBECTL -n ai-prod get secret layer-ai-prod-secrets >/dev/null 2>&1; then
  echo ""
  echo "WARN: secret layer-ai-prod-secrets missing in ai-prod."
  echo "      Create it before syncing gateway-api-prod / orchestrator-prod (docs/deploy-prod.md)."
fi

if grep -q 'REPLACE_PROD_TUNNEL_UUID' manifests/ingress/overlays/prod/cloudflared.yaml 2>/dev/null; then
  echo ""
  echo "WARN: prod tunnel UUID still REPLACE_PROD_TUNNEL_UUID — edit cloudflared.yaml before cloudflared-prod sync."
fi

echo ""
echo "== apply Argo CD Application CRs (prod) =="
for f in \
  argocd/applications/rag-query-prod.yaml \
  argocd/applications/mcp-github-prod.yaml \
  argocd/applications/orchestrator-prod.yaml \
  argocd/applications/gateway-api-prod.yaml \
  argocd/applications/web-prod.yaml \
  argocd/applications/cloudflared-prod.yaml
do
  echo "  $f"
  $KUBECTL apply -f "$f"
done

echo ""
echo "== next: manual Argo sync (after secrets + tunnel UUID) =="
echo "  1. rag-query-prod"
echo "  2. orchestrator-prod"
echo "  3. gateway-api-prod"
echo "  4. web-prod"
echo "  5. cloudflared-prod (prod tunnel Secret + DNS; docs/deploy-prod-cloudflare-tunnel.md)"
echo ""
echo "  $ARGOCD app sync rag-query-prod   # or Argo UI"
echo ""
echo "Observability (shared monitoring ns):"
echo "  $KUBECTL apply -k manifests/observability/"
