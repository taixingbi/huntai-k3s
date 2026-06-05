# GitOps with Argo CD

Argo CD watches [taixingbi/huntai-k3s](https://github.com/taixingbi/huntai-k3s) and applies manifests to the k3s cluster. Day-to-day deploys: commit YAML to `main` — do not `kubectl apply` app manifests manually.

## 1) Install Argo CD (one-time)

```bash
sudo k3s kubectl create namespace argocd

sudo k3s kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

sudo k3s kubectl get pods -n argocd
```

Wait until all pods are `Running`.

## 2) Argo CD UI

| Method | When |
|--------|------|
| [https://argocd.taixingai.com](https://argocd.taixingai.com) | **Recommended** — same Cloudflare Tunnel as dev web; stays up with the `cloudflared` Deployment ([deploy-dev-cloudflare-tunnel.md](deploy-dev-cloudflare-tunnel.md) §8) |
| `kubectl port-forward` | Local debug only; terminal must stay open |

**Tunnel (recommended):** After tunnel DNS and ingress are configured, open [https://argocd.taixingai.com](https://argocd.taixingai.com). One-time: set `argocd-cm` `url` and restart `argocd-server` — see [deploy-dev-cloudflare-tunnel.md](deploy-dev-cloudflare-tunnel.md) §8.

**Port-forward (optional fallback):**

```bash
sudo k3s kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Open [https://localhost:8080](https://localhost:8080) (accept the self-signed certificate). For LAN access from another machine, add `--address 0.0.0.0` and use `https://192.168.86.179:8080`.

Initial admin password:

```bash
sudo k3s kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo
```

Login: username `admin`, password from the command above.

## 3) Connect the Git repo (private repos only)

If `taixingbi/huntai-k3s` is private, add credentials in the Argo CD UI: **Settings → Repositories → Connect repo** (HTTPS token or SSH key).

Public repos work without extra configuration.

## 4) Bootstrap Applications

After pushing this repo to `main`:

```bash
cd ~/shared/huntai-k3s
git pull

# Recommended: applies projects + all Application CRs + huntai-apps (no argocd CLI)
./scripts/bootstrap-argocd.sh
```

Or minimal (only if `argocd` CLI is available to sync afterward):

```bash
sudo k3s kubectl apply -f argocd/app-of-apps.yaml
argocd app sync huntai-apps --grpc-web
```

**Do not** apply only `app-of-apps.yaml` before `git pull` — if `huntai-apps` syncs an empty/wrong `argocd/` path with **prune** enabled, child Applications can be **deleted** from the UI.

This creates Application `huntai-apps`, which syncs `argocd/` (AppProjects + child Applications). New apps: add YAML under `argocd/applications/`, list it in `argocd/applications/kustomization.yaml`, set `spec.project`, commit, push, run `./scripts/bootstrap-argocd.sh` or sync `huntai-apps` in the UI.

**Recovery** (all apps show `default` project, or most apps missing): `git pull` then `./scripts/bootstrap-argocd.sh`.

## 5) Verify sync

```bash
sudo k3s kubectl get applications -n argocd
sudo k3s kubectl get application huntai-apps -n argocd -o jsonpath='{.status.sync.status}{"\n"}{.status.health.status}{"\n"}'
sudo k3s kubectl get application vllm-inference -n argocd -o jsonpath='{.status.sync.status}{"\n"}{.status.health.status}{"\n"}'
sudo k3s kubectl get application observability -n argocd -o jsonpath='{.status.sync.status}{"\n"}{.status.health.status}{"\n"}'
sudo k3s kubectl get application gateway-api-dev -n argocd -o jsonpath='{.status.sync.status}{"\n"}{.status.health.status}{"\n"}'
sudo k3s kubectl get application gateway-inference-dev -n argocd -o jsonpath='{.status.sync.status}{"\n"}{.status.health.status}{"\n"}'
sudo k3s kubectl get application gateway-embedding-dev -n argocd -o jsonpath='{.status.sync.status}{"\n"}{.status.health.status}{"\n"}'
sudo k3s kubectl get application gateway-reranker-dev -n argocd -o jsonpath='{.status.sync.status}{"\n"}{.status.health.status}{"\n"}'
sudo k3s kubectl get application orchestrator-dev -n argocd -o jsonpath='{.status.sync.status}{"\n"}{.status.health.status}{"\n"}'
sudo k3s kubectl get application mcp-github-dev -n argocd -o jsonpath='{.status.sync.status}{"\n"}{.status.health.status}{"\n"}'
sudo k3s kubectl get application rag-query-dev -n argocd -o jsonpath='{.status.sync.status}{"\n"}{.status.health.status}{"\n"}'
sudo k3s kubectl get application web-dev -n argocd -o jsonpath='{.status.sync.status}{"\n"}{.status.health.status}{"\n"}'
sudo k3s kubectl get pods,svc -n ai-dev -l 'app in (layer-gateway-api,layer-gateway-inference,layer-gateway-embedding,layer-gateway-reranker,layer-orchestrator,layer-mcp-github,layer-rag-query,layer-web)'
```

In the UI:

- `gateway-api-dev` — **Synced** / **Healthy** when gateway secrets exist and orchestrator is reachable (`/ready` probe).
- `gateway-inference-dev` — **Synced** / **Healthy** when `layer-gateway-inference-secrets` exists and backend endpoints are reachable.
- `gateway-embedding-dev` — **Synced** / **Healthy** when embed backends in `EMBED_BACKENDS` are reachable.
- `gateway-reranker-dev` — **Synced** / **Healthy** when reranker backends in `RERANK_BACKENDS` are reachable.
- `orchestrator-dev` — **Synced** / **Healthy** when `layer-orchestrator-secrets` exists and dependencies (RAG, inference gateway, MCP) are up for your smoke paths.
- `mcp-github-dev` — **Synced** / **Healthy** when `layer-mcp-github-v1-secrets` exists and **layer-gateway-inference** is reachable.
- `rag-query-dev` — **Synced** / **Healthy** when Qdrant and gateway dependencies are reachable from `ai-dev`.
- `web-dev` — **Synced** / **Healthy** when `layer-gateway-api` is reachable and web root `/` probes pass.

## 6) Change workloads via Git

Edit files under `manifests/` (gateways, orchestrator, tool, rag, web, qdrant, ai, observability, ingress), commit, and push to `main`. Argo CD auto-syncs (`prune` + `selfHeal` enabled).

### Orchestrator image pin (automatic)

On every push to **`layer-orchestrator-v1` `main`**, CI builds the Docker image, then commits the **12-char Git SHA tag** into this repo:

- File: `manifests/orchestrator/overlays/dev/kustomization.yaml` → `images[].newTag`
- Argo Application `orchestrator-dev` sees the Git change and rolls out the Deployment.

Pushing only `:latest` to GHCR **without** a huntai-k3s commit does **not** trigger rollout (the Deployment spec in Git is unchanged).

**One-time secret** in [layer-orchestrator-v1](https://github.com/taixingbi/layer-orchestrator-v1) Actions: `HUNTAI_K3S_PAT` — PAT with **contents: write** on `taixingbi/huntai-k3s` only.

Verify pinned image after sync:

```bash
sudo k3s kubectl get deploy layer-orchestrator -n ai-dev \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

Optional image preload (use the pinned tag from Git, not only `:latest`):

```bash
TAG=$(grep newTag manifests/orchestrator/overlays/dev/kustomization.yaml | sed 's/.*"\(.*\)".*/\1/')
sudo k3s ctr images pull "ghcr.io/taixingbi/layer-orchestrator-v1:${TAG}"
```

### Gateway API, MCP GitHub, RAG, and web image pin (automatic)

Same pattern on push to app repos — **`dev`** pins dev overlays, **`main`** pins prod overlays (gateway-api, orchestrator, rag-query, web, mcp-github):

| App | Kustomize overlay | CI secret |
|-----|-------------------|-----------|
| `gateway-api-dev` | `manifests/gateway-api/overlays/dev/kustomization.yaml` | `HUNTAI_K3S_PAT` in gateway-api repo |
| `mcp-github-dev` / `mcp-github-prod` | `manifests/tool/overlays/dev` / `prod` | `HUNTAI_K3S_PAT` in mcp-github repo |
| `rag-query-dev` | `manifests/rag/overlays/dev/kustomization.yaml` | `HUNTAI_K3S_PAT` in rag-query repo |
| `web-dev` | `manifests/web/overlays/dev/kustomization.yaml` | `HUNTAI_K3S_PAT` in web repo |

## 7) GitHub webhook (faster refresh)

Argo CD can refresh immediately on GitHub push events instead of waiting for the default reconcile poll. Keep existing `syncPolicy.automated` in Applications; webhook only speeds up detection.

### Webhook URL and secret

Webhook endpoint:

```text
https://argocd.taixingai.com/api/webhook
```

Create and store a GitHub webhook secret in `argocd-secret`:

```bash
WEBHOOK_SECRET="$(openssl rand -hex 20)"
echo "Save this for GitHub webhook setup: ${WEBHOOK_SECRET}"

sudo k3s kubectl -n argocd patch secret argocd-secret \
  --type merge \
  -p "{\"stringData\":{\"webhook.github.secret\":\"${WEBHOOK_SECRET}\"}}"
```

### GitHub repository settings

In `taixingbi/huntai-k3s`:

- Settings -> Webhooks -> Add webhook
- Payload URL: `https://argocd.taixingai.com/api/webhook`
- Content type: `application/json`
- Secret: same `WEBHOOK_SECRET` from above
- SSL verification: enabled
- Events: "Just the push event"

After saving, open **Recent Deliveries**, redeliver the latest event, and confirm `200`.

### Verify refresh and sync

```bash
sudo k3s kubectl get application orchestrator-dev -n argocd \
  -o jsonpath='{.status.reconciledAt}{"\n"}{.status.sync.status}{"\n"}'
```

You should see `reconciledAt` update within seconds after a push. Rollout speed still depends on image pull and Kubernetes Deployment update timing.

### Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Delivery `401`/`403` | Secret mismatch | Re-patch `argocd-secret` and update GitHub webhook secret |
| Delivery `404` | Wrong endpoint or hostname routing | Confirm URL is `https://argocd.taixingai.com/api/webhook` and tunnel routes Argo CD |
| Delivery `502` | Tunnel/backend issue | Check `cloudflared` and `argocd-server` health |
| Delivery `200`, no rollout | No manifest change in `huntai-k3s` | Confirm CI updated `kustomization.yaml` `newTag` on `main` |

If you later protect `argocd.taixingai.com` with Cloudflare Access, keep `/api/webhook` reachable by GitHub (bypass path or use a service token policy).

## Layout

```
argocd/app-of-apps.yaml              # one-time bootstrap → Application huntai-apps
argocd/kustomization.yaml            # projects + applications (huntai-apps sync root)
argocd/projects/                     # AppProject: platform, ai-dev, ai-prod
argocd/applications/                 # child Application CRs (kustomization.yaml lists all)
manifests/vllm/                          # vLLM bundle chat+embed+rerank (vllm-inference)
manifests/qdrant/overlays/dev/       # qdrant-dev
manifests/observability/             # Prometheus + Alloy (observability)
manifests/gateway-*/overlays/dev/    # inference, embedding, reranker, api gateways
manifests/orchestrator/overlays/dev/
manifests/tool/overlays/dev/         # mcp-github-dev
manifests/rag/overlays/dev/
manifests/web/overlays/dev/
manifests/ingress/overlays/dev       # cloudflared-dev
manifests/ingress/overlays/prod      # cloudflared-prod (manual sync)
```

## Secrets

Never commit secrets. Create cluster secrets manually before sync — see [cluster-secrets.md](cluster-secrets.md). Grafana Cloud Prometheus/Loki tokens: [secrets/README.md](../secrets/README.md) (outside Argo-managed manifests). State backup: [backup-restore.md](backup-restore.md).

Upgrading from older commits that embedded placeholder Secrets in `manifests/observability/`: orphan labels per [secrets/README.md](../secrets/README.md) **before** syncing, or recreate secrets after sync.

**Stateful data:** PVCs `prometheus-data` and `qdrant-data` are annotated `argocd.argoproj.io/sync-options: Prune=false` so app-of-apps prune does not delete TSDB/Qdrant volumes. Other resources still prune when removed from Git.

## Argo CD projects

Child apps are grouped by **AppProject** (RBAC and allowed destinations). `huntai-apps` stays on project `default`.

| Project | Applications | Allowed namespaces |
|---------|----------------|-------------------|
| **platform** | `observability`, `vllm-inference`, `cloudflared-dev`, `cloudflared-prod` | `monitoring`, `vllm`, `ai-dev`, `ai-prod` (tunnels only) |
| **ai-dev** | `qdrant-dev`, `gateway-*-dev`, `rag-query-dev`, `orchestrator-dev`, `mcp-github-dev`, `gateway-api-dev`, `web-dev` | `ai-dev` only |
| **ai-prod** | `rag-query-prod`, `mcp-github-prod`, `orchestrator-prod`, `gateway-api-prod`, `web-prod` | `ai-prod` only |

Prod apps remain **manual sync** (no `automated` on those Application CRs). `ai-prod` project blocks deploying prod overlays into `ai-dev`.

Definitions: `argocd/projects/*.yaml`.

## Rollout order (sync waves)

Argo CD sync waves order cold start roughly as:

| Wave | Argo Application | Manifest path |
|------|------------------|---------------|
| 0 | `vllm-inference` | `manifests/vllm` |
| 1 | `observability` | `manifests/observability` |
| 2 | `qdrant-dev`, `gateway-inference-dev`, `gateway-embedding-dev`, `gateway-reranker-dev` | `manifests/qdrant/overlays/dev`, `manifests/gateway-*/overlays/dev` |
| 3 | `rag-query-dev`, `mcp-github-dev` | `manifests/rag/overlays/dev`, `manifests/tool/overlays/dev` |
| 4 | `orchestrator-dev` | `manifests/orchestrator/overlays/dev` |
| 5 | `gateway-api-dev` | `manifests/gateway-api/overlays/dev` |
| 6 | `web-dev` | `manifests/web/overlays/dev` |
| 9 | `cloudflared-dev` | `manifests/ingress/overlays/dev` |
| 12 | `cloudflared-prod` | `manifests/ingress/overlays/prod` (manual) |
| 10 | `rag-query-prod`, `orchestrator-prod`, `gateway-api-prod` | `manifests/*/overlays/prod` (manual sync) |
| 11 | `web-prod` | `manifests/web/overlays/prod` |

**Argo OutOfSync (dev):** Review **Diff** before **Sync** on `gateway-*-dev` so Git does not revert hand-tuned `EMBED_BACKENDS` / `RERANK_BACKENDS`. Prod apps only touch `ai-prod` overlays — they cannot change `ai-dev` gateway Deployments.

Add a new app: create `argocd/applications/<name>.yaml`, set `spec.project` (`platform` | `ai-dev` | `ai-prod`), list it in `argocd/applications/kustomization.yaml`, commit, push — `huntai-apps` picks it up automatically.
