#!/usr/bin/env bash
# Roll out ai-prod user stack in dependency order (kubectl apply; Argo manual-sync apps).
# Requires layer-ai-prod-secrets and layer-mcp-github-v1-secrets. Skips cloudflared (tunnel UUID + credentials).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

KUBECTL="${KUBECTL:-sudo k3s kubectl}"

if ! $KUBECTL -n ai-prod get secret layer-ai-prod-secrets >/dev/null 2>&1; then
  echo "error: secret layer-ai-prod-secrets missing in ai-prod (docs/deploy-prod.md)"
  exit 1
fi

git pull --ff-only origin main

for script in \
  sync-rag-query-prod.sh \
  sync-mcp-github-prod.sh \
  sync-orchestrator-prod.sh \
  sync-gateway-api-prod.sh \
  sync-web-prod.sh
do
  echo ""
  echo "======== ${script} ========"
  bash "${ROOT}/scripts/${script}"
done

echo ""
echo "== cloudflared-prod (after tunnel UUID + credentials) =="
echo "  docs/deploy-prod-cloudflare-tunnel.md"
