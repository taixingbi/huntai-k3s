# Deploy prod user stack (`ai-prod`)

Prod runs **gateway-api**, **orchestrator**, **web**, and **rag-query** in namespace **`ai-prod`**. Shared GPU plane stays in **`vllm`** + **`ai-dev`** (inference/embed/rerank gateways, Qdrant, MCP).

Architecture: [architecture.md](architecture.md). Ports: [port.md](port.md).

## Before first sync

1. Create **`layer-ai-prod-secrets`** in `ai-prod` (prod Supabase + Tavily/LangSmith — **not** dev keys). See [cluster-secrets.md](cluster-secrets.md).
2. Confirm **`ai-dev`** GPU gateways and Qdrant are healthy.
3. Argo prod apps use **manual sync** (no auto-sync) so prod cannot overwrite dev gateway manifests.

## Create prod secret (example keys)

```bash
mkdir -p ~/.secrets/prod
chmod 700 ~/.secrets/prod

# Prod Supabase (gateway-api) — from prod project dashboard
printf '%s' 'YOUR_PROD_SUPABASE_URL' > ~/.secrets/prod/supabase-url
printf '%s' 'YOUR_PROD_SUPABASE_ANON_KEY' > ~/.secrets/prod/supabase-anon-key
# Add other keys per deploy-gateway-api.md (JWKS, service role if used)

printf '%s' 'tvly_YOUR_PROD_KEY' > ~/.secrets/prod/tavily-api-key

sudo k3s kubectl create secret generic layer-ai-prod-secrets -n ai-prod \
  --from-literal=SUPABASE_URL="$(cat ~/.secrets/prod/supabase-url)" \
  --from-literal=SUPABASE_ANON_KEY="$(cat ~/.secrets/prod/supabase-anon-key)" \
  --from-literal=TAVILY_API_KEY="$(cat ~/.secrets/prod/tavily-api-key)" \
  --dry-run=client -o yaml | sudo k3s kubectl apply -f -
```

Adjust keys to match upstream `env.example` for gateway-api and orchestrator. See `secrets/examples/layer-ai-prod-secrets.secret.example.yaml`.

## Argo CD applications (manual sync)

| Application | Path | Namespace |
|-------------|------|-----------|
| `rag-query-prod` | `manifests/rag/overlays/prod` | `ai-prod` |
| `orchestrator-prod` | `manifests/orchestrator/overlays/prod` | `ai-prod` |
| `gateway-api-prod` | `manifests/gateway-api/overlays/prod` | `ai-prod` |
| `web-prod` | `manifests/web/overlays/prod` | `ai-prod` |
| `cloudflared-prod` | `manifests/ingress/overlays/prod` | `ai-prod` |

Sync order: **rag → orchestrator → gateway-api → web → cloudflared** (waves 10–12). In UI: **Diff** each app — prod must **not** change `ai-dev` gateway Deployments.

### layer-rag-query-v1 → prod image pin

Policy: merge **`dev` → `main`** in [layer-rag-query-v1](https://github.com/taixingbi/layer-rag-query-v1) (no direct push to `main`). CI on **`main`** commits to `manifests/rag/overlays/prod/kustomization.yaml` in huntai-k3s (`chore(rag-query-prod): pin image …`).

```bash
# On server after main merge + CI green:
cd ~/shared/huntai-platform/huntai-k3s
./scripts/sync-rag-query-prod.sh
# Argo UI → Sync rag-query-prod
```

Verify: `sudo k3s kubectl -n ai-prod get pods -l app=layer-rag-query` → **Running**; image tag matches [prod kustomization](../manifests/rag/overlays/prod/kustomization.yaml).

```bash
./scripts/deploy-ai-prod.sh
# After layer-ai-prod-secrets exists, sync remaining prod apps in Argo UI
```

## Prod-specific config (in overlays)

| Setting | Prod value |
|---------|------------|
| `ORCHESTRATOR_TIMEOUT_MS` | `120000` (dev patched too) |
| `RAG_COLLECTION_BASE` | `taixing_knowledge_prod` |
| `FRONTEND_URL` / `APP_URL` | `https://taixingai.com` (edit overlay if hostname differs) |
| Orchestrator `LLM_GATEWAY_BASE_URL` | `http://layer-gateway-inference.ai-dev.svc.cluster.local:8000` |
| RAG `QDRANT_URL` | `http://qdrant.ai-dev.svc.cluster.local:6333` |
| RAG embed/infer/rerank URLs | `http://layer-gateway-*.ai-dev.svc.cluster.local:800x` |

## Observability

- Prometheus scrapes **`ai-prod`** for `layer-gateway-api`, `layer-orchestrator`, `layer-rag-query` (`environment` label = namespace).
- Loki alerts: `grafana-import/alert/loki-gateway-log-level-alerts.yaml` (WARN/ERROR for `ai-prod`).
- Apply observability manifest after pull: `sudo k3s kubectl apply -k manifests/observability/`

## Public URL

Prod tunnel manifest and runbook: [deploy-prod-cloudflare-tunnel.md](deploy-prod-cloudflare-tunnel.md). Replace `REPLACE_PROD_TUNNEL_UUID` in `manifests/ingress/overlays/prod/cloudflared.yaml`, create `cloudflared-tunnel-credentials` in `ai-prod`, then sync **`cloudflared-prod`** after **`web-prod`**.

## Do not sync these to prod

- `gateway-inference-dev`, `gateway-embedding-dev`, `gateway-reranker-dev`
- `qdrant-dev`, `vllm-inference`, `mcp-github-dev` (optional: prod orchestrator calls MCP in `ai-dev`)
