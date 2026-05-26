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
sudo k3s kubectl get secret layer-orchestrator-secrets -n ai-dev

# Register Applications (one-time; workloads sync from Git after push)
sudo k3s kubectl apply -f argocd/applications/gateway-api-dev.yaml
sudo k3s kubectl apply -f argocd/applications/orchestrator-dev.yaml
```

## 5) Verify sync

```bash
sudo k3s kubectl get applications -n argocd
sudo k3s kubectl get application gateway-api-dev -n argocd -o jsonpath='{.status.sync.status}{"\n"}{.status.health.status}{"\n"}'
sudo k3s kubectl get application orchestrator-dev -n argocd -o jsonpath='{.status.sync.status}{"\n"}{.status.health.status}{"\n"}'
sudo k3s kubectl get pods,svc -n ai-dev -l 'app in (layer-gateway-api,layer-orchestrator)'
```

In the UI:

- `gateway-api-dev` — **Synced** / **Healthy** when gateway secrets exist and orchestrator is reachable (`/ready` probe).
- `orchestrator-dev` — **Synced** / **Healthy** when `layer-orchestrator-secrets` exists and dependencies (RAG, inference gateway, MCP) are up for your smoke paths.

## 6) Change workloads via Git

Edit files under `manifests/gateway-api/` or `manifests/orchestrator/`, commit, and push to `main`. Argo CD auto-syncs (`prune` + `selfHeal` enabled).

Optional image preload after upstream CI:

```bash
sudo k3s ctr images pull docker.io/taixingbi/layer-gateway-api-v1:latest
```

## Layout

```
argocd/applications/gateway-api-dev.yaml      # Argo CD Application (bootstrap via kubectl)
argocd/applications/orchestrator-dev.yaml
manifests/gateway-api/
├── base/                                       # Deployment + Service
└── overlays/dev/                               # namespace ai-dev, dev env
manifests/orchestrator/
├── base/
└── overlays/dev/
```

## Secrets

Never commit secrets. Create cluster secrets manually in `ai-dev` (e.g. `layer-gateway-api-secrets`, `layer-orchestrator-secrets`). See [deploy-gateway-api.md](deploy-gateway-api.md) §1 and [deploy-orchestrator.md](deploy-orchestrator.md) §1.

## Rollout order for more apps

| Phase | Argo Application | Manifest path |
|-------|------------------|---------------|
| 1 | `gateway-api-dev` | `manifests/gateway-api/overlays/dev` |
| 2 (now) | `orchestrator-dev` | `manifests/orchestrator/overlays/dev` |
| 3 | `rag-query-dev` | `manifests/rag/...` |
| 4+ | inference, embed, reranker, web, cloudflared | see plan in repo history |

Optional later: an **app-of-apps** Application pointing at `argocd/applications/` so new apps need only a Git commit.
