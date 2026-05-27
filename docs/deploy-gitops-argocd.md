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

# Secrets must exist before pods start
sudo k3s kubectl get secret layer-gateway-api-secrets -n ai-dev
sudo k3s kubectl get secret layer-gateway-inference-secrets -n ai-dev
sudo k3s kubectl get secret layer-orchestrator-secrets -n ai-dev
sudo k3s kubectl get secret layer-mcp-github-v1-secrets -n ai-dev

# Register Applications (one-time; workloads sync from Git after push)
sudo k3s kubectl apply -f argocd/applications/gateway-api-dev.yaml
sudo k3s kubectl apply -f argocd/applications/gateway-inference-dev.yaml
sudo k3s kubectl apply -f argocd/applications/gateway-embedding-dev.yaml
sudo k3s kubectl apply -f argocd/applications/gateway-reranker-dev.yaml
sudo k3s kubectl apply -f argocd/applications/orchestrator-dev.yaml
sudo k3s kubectl apply -f argocd/applications/mcp-github-dev.yaml
sudo k3s kubectl apply -f argocd/applications/rag-query-dev.yaml
sudo k3s kubectl apply -f argocd/applications/web-dev.yaml
```

## 5) Verify sync

```bash
sudo k3s kubectl get applications -n argocd
sudo k3s kubectl get application gateway-api-dev -n argocd -o jsonpath='{.status.sync.status}{"\n"}{.status.health.status}{"\n"}'
sudo k3s kubectl get application gateway-inference-dev -n argocd -o jsonpath='{.status.sync.status}{"\n"}{.status.health.status}{"\n"}'
sudo k3s kubectl get application gateway-embedding-dev -n argocd -o jsonpath='{.status.sync.status}{"\n"}{.status.health.status}{"\n"}'
sudo k3s kubectl get application gateway-reranker-dev -n argocd -o jsonpath='{.status.sync.status}{"\n"}{.status.health.status}{"\n"}'
sudo k3s kubectl get application orchestrator-dev -n argocd -o jsonpath='{.status.sync.status}{"\n"}{.status.health.status}{"\n"}'
sudo k3s kubectl get application mcp-github-dev -n argocd -o jsonpath='{.status.sync.status}{"\n"}{.status.health.status}{"\n"}'
sudo k3s kubectl get application rag-query-dev -n argocd -o jsonpath='{.status.sync.status}{"\n"}{.status.health.status}{"\n"}'
sudo k3s kubectl get application web-dev -n argocd -o jsonpath='{.status.sync.status}{"\n"}{.status.health.status}{"\n"}'
sudo k3s kubectl get pods,svc -n ai-dev -l 'app in (layer-gateway-api,layer-gateway-inference,layer-gateway-embedding,layer-gateway-reranker,layer-orchestrator,layer-mcp-github-v1,layer-rag-query,layer-web)'
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

Edit files under `manifests/gateway-api/`, `manifests/gateway-inference/`, `manifests/gateway-embedding/`, `manifests/gateway-reranker/`, `manifests/orchestrator/`, `manifests/tool/`, `manifests/rag/`, or `manifests/web/`, commit, and push to `main`. Argo CD auto-syncs (`prune` + `selfHeal` enabled).

### Orchestrator image pin (automatic)

On every push to **`layer-orchestrator-v1` `main`**, CI builds the Docker image, then commits the **12-char Git SHA tag** into this repo:

- File: `manifests/orchestrator/overlays/dev/kustomization.yaml` → `images[].newTag`
- Argo Application `orchestrator-dev` sees the Git change and rolls out the Deployment.

Pushing only `:latest` to Docker Hub **without** a huntai-k3s commit does **not** trigger rollout (the Deployment spec in Git is unchanged).

**One-time secret** in [layer-orchestrator-v1](https://github.com/taixingbi/layer-orchestrator-v1) Actions: `HUNTAI_K3S_PAT` — PAT with **contents: write** on `taixingbi/huntai-k3s` only.

Verify pinned image after sync:

```bash
sudo k3s kubectl get deploy layer-orchestrator -n ai-dev \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

Optional image preload (use the pinned tag from Git, not only `:latest`):

```bash
TAG=$(grep newTag manifests/orchestrator/overlays/dev/kustomization.yaml | sed 's/.*"\(.*\)".*/\1/')
sudo k3s ctr images pull "docker.io/taixingbi/layer-orchestrator-v1:${TAG}"
```

### Gateway API, MCP GitHub, RAG, and web image pin (automatic)

Same pattern on push to **`layer-gateway-api-v1`** / **`layer-mcp-github-v1`** / **`layer-rag-query-v1`** / **`layer-web-v1`** `main`:

| App | Kustomize overlay | CI secret |
|-----|-------------------|-----------|
| `gateway-api-dev` | `manifests/gateway-api/overlays/dev/kustomization.yaml` | `HUNTAI_K3S_PAT` in gateway-api repo |
| `mcp-github-dev` | `manifests/tool/overlays/dev/kustomization.yaml` | `HUNTAI_K3S_PAT` in mcp-github repo |
| `rag-query-dev` | `manifests/rag/overlays/dev/kustomization.yaml` | `HUNTAI_K3S_PAT` in rag-query repo |
| `web-dev` | `manifests/web/overlays/dev/kustomization.yaml` | `HUNTAI_K3S_PAT` in web repo |

## Layout

```
argocd/applications/gateway-api-dev.yaml      # Argo CD Application (bootstrap via kubectl)
argocd/applications/gateway-inference-dev.yaml
argocd/applications/gateway-embedding-dev.yaml
argocd/applications/gateway-reranker-dev.yaml
argocd/applications/orchestrator-dev.yaml
argocd/applications/mcp-github-dev.yaml
argocd/applications/rag-query-dev.yaml
argocd/applications/web-dev.yaml
manifests/gateway-api/
├── base/                                       # Deployment + Service
└── overlays/dev/                               # namespace ai-dev, dev env
manifests/gateway-inference/
├── base/                                       # ConfigMap + Deployment + Service
└── overlays/dev/
manifests/gateway-embedding/
├── base/
└── overlays/dev/
manifests/gateway-reranker/
├── base/
└── overlays/dev/
manifests/orchestrator/
├── base/
└── overlays/dev/
manifests/tool/                                 # layer-mcp-github-v1 (mcp-github-dev)
├── base/
└── overlays/dev/
manifests/rag/                                  # layer-rag-query-v1 (rag-query-dev)
├── base/
└── overlays/dev/
manifests/web/                                  # layer-web-v1 (web-dev)
├── base/
└── overlays/dev/
```

## Secrets

Never commit secrets. Create cluster secrets manually in `ai-dev` (e.g. `layer-gateway-api-secrets`, `layer-orchestrator-secrets`). See [deploy-gateway-api.md](deploy-gateway-api.md) §1 and [deploy-orchestrator.md](deploy-orchestrator.md) §1.

## Rollout order for more apps

| Phase | Argo Application | Manifest path |
|-------|------------------|---------------|
| 1 | `gateway-api-dev` | `manifests/gateway-api/overlays/dev` |
| 2 | `gateway-inference-dev` | `manifests/gateway-inference/overlays/dev` |
| 3 | `gateway-embedding-dev` | `manifests/gateway-embedding/overlays/dev` |
| 4 | `gateway-reranker-dev` | `manifests/gateway-reranker/overlays/dev` |
| 5 | `orchestrator-dev` | `manifests/orchestrator/overlays/dev` |
| 6 | `mcp-github-dev` | `manifests/tool/overlays/dev` |
| 7 | `rag-query-dev` | `manifests/rag/overlays/dev` |
| 8 | `web-dev` | `manifests/web/overlays/dev` |
| 9+ | cloudflared | see plan in repo history |

Optional later: an **app-of-apps** Application pointing at `argocd/applications/` so new apps need only a Git commit.
