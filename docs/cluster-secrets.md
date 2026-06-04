# Cluster secrets (manual bootstrap)

Secrets are **never** committed to Git (Grafana Cloud tokens are **not** in `manifests/observability/` — Argo `selfHeal` must not reset them). Create each once before the corresponding Argo CD Application syncs. Store values under `~/.secrets/` on the control plane (`chmod 700` dir, `600` files).

Grafana Cloud: [secrets/README.md](../secrets/README.md) (bootstrap commands, rotation, upgrade from old Git placeholders).

## ai-dev

| Secret | Used by | Create |
|--------|---------|--------|
| `layer-gateway-api-secrets` | gateway-api | [deploy-gateway-api.md](deploy-gateway-api.md) §1 |
| `layer-gateway-inference-secrets` | gateway-inference | [deploy-gateway-inference.md](deploy-gateway-inference.md) §1 |
| `layer-orchestrator-secrets` | orchestrator | [deploy-orchestrator.md](deploy-orchestrator.md) §1 |
| `layer-mcp-github-v1-secrets` | mcp-github (manifests/tool) | [deploy-mcp-github.md](deploy-mcp-github.md) §1 |
| `cloudflared-tunnel-credentials` | cloudflared (`ai-dev`) | [deploy-dev-cloudflare-tunnel.md](deploy-dev-cloudflare-tunnel.md) |
| `cloudflared-tunnel-credentials` | cloudflared (`ai-prod`) | [deploy-prod-cloudflare-tunnel.md](deploy-prod-cloudflare-tunnel.md) |

RAG and embedding/reranker gateways do not use `secretRef` in dev manifests by default.

## ai-prod (prod user stack)

| Secret | Used by | Create |
|--------|---------|--------|
| `layer-ai-prod-secrets` | gateway-api-prod, orchestrator-prod | [deploy-prod.md](deploy-prod.md) |

Use a **prod Supabase project** and **prod Tavily** key — do not copy `ai-dev` secret bytes. Example template: `secrets/examples/layer-ai-prod-secrets.secret.example.yaml`.

Shared backends (inference/embed/rerank gateways, Qdrant) stay in **`ai-dev`** — no prod secrets for those apps.

## monitoring

| Secret | Used by | Create |
|--------|---------|--------|
| `prometheus-grafana-cloud-remote-write` | Prometheus | [deploy-prometheus.md](deploy-prometheus.md) |
| `alloy-grafana-cloud-loki` | Alloy | [deploy-alloy-loki.md](deploy-alloy-loki.md) |

## Verify before app-of-apps sync

```bash
sudo k3s kubectl get secret layer-gateway-api-secrets -n ai-dev
sudo k3s kubectl get secret layer-gateway-inference-secrets -n ai-dev
sudo k3s kubectl get secret layer-orchestrator-secrets -n ai-dev
sudo k3s kubectl get secret layer-mcp-github-v1-secrets -n ai-dev
sudo k3s kubectl get secret cloudflared-tunnel-credentials -n ai-dev
sudo k3s kubectl get secret prometheus-grafana-cloud-remote-write -n monitoring
sudo k3s kubectl get secret alloy-grafana-cloud-loki -n monitoring
```

## Rotation

Update the Secret with `kubectl create secret ... --dry-run=client -o yaml | kubectl apply -f -`, then rollout restart the Deployment/DaemonSet that references it.

**Do not** add these Secrets back into `manifests/observability/` — that recreates the 401 / token overwrite problem with Argo automated sync.

## Future

External Secrets Operator or SOPS can move secret *references* into Git while values stay in a vault; not required for homelab dev today.
