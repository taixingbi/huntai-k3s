# AGENTS.md — huntai-k3s operator guide

Repo: GitOps manifests for HuntAI on **k3s** (control plane + 2× GPU). App code lives in separate `layer-*` repos; images are pinned in `manifests/*/overlays/dev/kustomization.yaml`.

## Layout

| Path | Purpose |
|------|---------|
| `argocd/projects/` | AppProjects: platform, ai-dev, ai-prod |
| `argocd/applications/` | Argo CD Application CRs (sync waves; `spec.project` set) |
| `manifests/vllm/` | GPU bundle namespace `vllm` |
| `manifests/gateway-*/`, `orchestrator/`, `rag/`, `web/`, `tool/` | Apps in `ai-dev` (`tool/` = GitHub MCP, Argo app `mcp-github-dev`) |
| `manifests/observability/` | Prometheus + Alloy (`monitoring`) |
| `secrets/` | Grafana Cloud token bootstrap (not in Git manifests) |
| `grafana-import/` | Dashboards + alert YAML for Grafana Cloud |
| `docs/` | Runbooks; start at `docs/architecture.md`, `docs/port.md` |

## Rules

1. **Never commit** real tokens. Grafana secrets: `secrets/README.md`. App secrets: `docs/cluster-secrets.md`.
2. **Do not** add `Secret` objects under `manifests/observability/` (Argo selfHeal overwrote tokens).
3. **Gateways → vLLM** use per-node ClusterIP DNS (`vllm-chat-gpu-node-*`, etc.) — see `docs/architecture.md`.
4. **Prometheus** queries use label `workload=` (not only `job=`). Inference has 3 `model_name` per GPU (base/sft/dpo).
5. **Argo sync** OutOfSync apps: diff before sync; PVCs have `Prune=false`.
6. **Images:** pin via overlay `images[]` + digest; CI uses `scripts/pin-gitops-image.sh`.

## Validate locally

```bash
./scripts/validate-kustomize.sh
./scripts/sync-grafana-dashboards.sh --print-versions
```

## Prod (`ai-prod`)

User-facing prod: gateway-api, orchestrator, web, rag, cloudflared — [docs/deploy-prod.md](docs/deploy-prod.md), tunnel [docs/deploy-prod-cloudflare-tunnel.md](docs/deploy-prod-cloudflare-tunnel.md). Bootstrap: `./scripts/deploy-ai-prod.sh`. GPU gateways + Qdrant stay in `ai-dev`. Secret: `layer-ai-prod-secrets` (not dev secrets).

## Deploy order (cold start)

1. Cluster secrets → `docs/cluster-secrets.md` + `secrets/README.md`
2. `kubectl apply -f argocd/app-of-apps.yaml`
3. Wait for `vllm-inference`, `observability`, then gateways (`deploy-gitops-argocd.md` sync waves)

## Smokes

`docs/test-calls.md` — prefer ClusterIP from control plane for gateway `/ready`.
