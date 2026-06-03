# Deploy Workloads And Observability

GitOps (Argo CD) for the gateway API and future apps: [deploy-gitops-argocd.md](deploy-gitops-argocd.md).

Deployment steps are split by component:

1. vLLM inference: `docs/deploy-vllm-inference.md`
2. Qdrant (dev): `docs/deploy-qdrant.md`
3. inference gateway (dev): `docs/deploy-gateway-inference.md`
4. embedding gateway (dev): `docs/deploy-gateway-embedding.md`
5. reranker gateway (dev): `docs/deploy-gateway-reranker.md`
6. RAG query (dev): `docs/deploy-rag-query.md`
7. Orchestrator (dev): `docs/deploy-orchestrator.md`
8. Gateway API + web (dev): `docs/deploy-gateway-api.md`, `docs/deploy-layer-web.md`
9. Dev public URL (Cloudflare Tunnel): `docs/deploy-dev-cloudflare-tunnel.md`
10. layer-mcp-github-v1 (dev): `docs/deploy-layer-mcp-github.md`
11. Prometheus remote_write: `docs/deploy-prometheus.md`
12. Alloy + Loki: `docs/deploy-alloy-loki.md`
13. Grafana import: `grafana-import/README.md`

