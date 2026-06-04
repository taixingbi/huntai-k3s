# Deploy Workloads And Observability

GitOps (Argo CD) for the gateway API and future apps: [deploy-gitops-argocd.md](deploy-gitops-argocd.md).

**Architecture** (namespaces, gateway → vLLM URLs, metrics): [architecture.md](architecture.md).

If embed, rerank, inference gateways, or vLLM Grafana metrics broke after the `ai` → `vllm` move, use **`docs/fix-vllm-plane-cutover.md`** first.

Deployment steps are split by component:

1. vLLM inference (bundle): `docs/deploy-vllm-inference.md`
   - vLLM embedding (`:8001`): `docs/deploy-vllm-embedding.md`
   - vLLM reranker (`:8002`): `docs/deploy-vllm-reranker.md`
2. Qdrant (dev): `docs/deploy-qdrant.md`
3. inference gateway (dev): `docs/deploy-gateway-inference.md`
4. embedding gateway (dev): `docs/deploy-gateway-embedding.md`
5. reranker gateway (dev): `docs/deploy-gateway-reranker.md`
6. RAG query (dev): `docs/deploy-rag-query.md`
7. Orchestrator (dev): `docs/deploy-orchestrator.md`
8. Gateway API + web (dev): `docs/deploy-gateway-api.md`, `docs/deploy-web.md`
9. Dev public URL (Cloudflare Tunnel): `docs/deploy-dev-cloudflare-tunnel.md`
10. GitHub MCP (dev): `docs/deploy-mcp-github.md` (manifests `tool/`, Argo `mcp-github-dev`)
11. Prometheus remote_write: `docs/deploy-prometheus.md`
12. Alloy + Loki: `docs/deploy-alloy-loki.md`
13. Grafana import: `grafana-import/README.md`

