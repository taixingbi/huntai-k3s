# GitOps with Argo CD

Argo CD watches [taixingbi/k3s-huntai](https://github.com/taixingbi/k3s-huntai) and applies manifests to the k3s cluster. Day-to-day deploys: commit YAML to `main` — do not `kubectl apply` app manifests manually.

## 1) Install Argo CD (one-time)

```bash
sudo k3s kubectl create namespace argocd

sudo k3s kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

sudo k3s kubectl get pods -n argocd
```

Wait until all pods are `Running`.

## 2) Argo CD UI

```bash
sudo k3s kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Open [https://localhost:8080](https://localhost:8080) (accept the self-signed certificate).

Initial admin password:

```bash
sudo k3s kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo
```

Login: username `admin`, password from the command above.

## 3) Connect the Git repo (private repos only)

If `taixingbi/k3s-huntai` is private, add credentials in the Argo CD UI: **Settings → Repositories → Connect repo** (HTTPS token or SSH key).

Public repos work without extra configuration.

## 4) Bootstrap the first Application

After pushing this repo to `main`:

```bash
cd ~/shared/k3s-huntai

# Auth secret must exist before pods start (see deploy-gateway-api.md §1)
sudo k3s kubectl get secret layer-gateway-api-secrets -n ai-dev

# Register the Application (one-time; not yet synced from Git)
sudo k3s kubectl apply -f argocd/applications/gateway-api-dev.yaml
```

## 5) Verify sync

```bash
sudo k3s kubectl get applications -n argocd
sudo k3s kubectl get application gateway-api-dev -n argocd -o jsonpath='{.status.sync.status}{"\n"}{.status.health.status}{"\n"}'
sudo k3s kubectl get pods,svc -n ai-dev -l app=layer-gateway-api
```

In the UI, `gateway-api-dev` should show **Synced** and **Healthy** once the secret exists and orchestrator is reachable (`/ready` probe).

## 6) Change the gateway API

Edit files under `manifests/gateway-api/`, commit, and push to `main`. Argo CD auto-syncs (`prune` + `selfHeal` enabled).

Optional image preload after upstream CI:

```bash
sudo k3s ctr images pull docker.io/taixingbi/layer-gateway-api-v1:latest
```

## Layout

```
argocd/applications/gateway-api-dev.yaml   # Argo CD Application (bootstrap via kubectl)
manifests/gateway-api/
├── base/                                   # Deployment + Service
└── overlays/dev/                           # namespace ai-dev, dev env
```

## Secrets

Never commit secrets. Create cluster secrets manually (e.g. `layer-gateway-api-secrets` in `ai-dev`). See [deploy-gateway-api.md](deploy-gateway-api.md) §1.

## Rollout order for more apps

| Phase | Argo Application | Manifest path |
|-------|------------------|---------------|
| 1 (now) | `gateway-api-dev` | `manifests/gateway-api/overlays/dev` |
| 2 | `orchestrator-dev` | `manifests/orchestrator/...` (to migrate) |
| 3 | `rag-query-dev` | `manifests/rag/...` |
| 4+ | inference, embed, reranker, web, cloudflared | see plan in repo history |

Optional later: an **app-of-apps** Application pointing at `argocd/applications/` so new apps need only a Git commit.
