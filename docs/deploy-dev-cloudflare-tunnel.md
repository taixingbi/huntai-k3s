# Dev public URL — Cloudflare Tunnel

Expose dev services over HTTPS without opening inbound ports:

- **`dev.taixingai.com`** — HuntAI web UI (`layer-web:3000`)
- **`argocd.taixingai.com`** — Argo CD UI (`argocd-server:443`)

**Dev only** — prod (`ai-prod`, apex DNS) is a separate tunnel manifest later.

## Architecture (recommended: in-cluster)

```mermaid
flowchart TD
  browserDev[Browser dev.taixingai.com]
  browserArgo[Browser argocd.taixingai.com]
  cf[Cloudflare edge]
  tun[cloudflared Deployment ai-dev]
  web[layer-web Service :3000]
  argo[argocd-server :443]
  gw[layer-gateway-api :8000]
  orch[layer-orchestrator]
  rag[layer-rag-query]
  browserDev -->|HTTPS| cf
  browserArgo -->|HTTPS| cf
  cf --> tun
  tun -->|HTTP cluster DNS| web
  tun -->|HTTPS noTLSVerify| argo
  web --> gw
  gw --> orch
  orch --> rag
```

| Layer | Kubernetes name | Notes |
|-------|-----------------|--------|
| Tunnel connector | **`cloudflared`** Deployment | [`manifests/ingress/cloudflared-dev.yaml`](../manifests/ingress/cloudflared-dev.yaml) |
| Web UI + BFF | **`layer-web`** Service | Image `layer-web-v1`; port **3000** |
| Argo CD UI | **`argocd-server`** Service (`argocd` ns) | HTTPS; `originRequest.noTLSVerify` on tunnel |
| Gateway | **`layer-gateway-api`** | ClusterIP only |
| NodePort (LAN debug) | **30186** | Optional; not used by in-cluster tunnel |

Backend URLs inside the cluster:

- Web: `http://layer-web.ai-dev.svc.cluster.local:3000`
- Argo CD: `https://argocd-server.argocd.svc.cluster.local:443`

## Prerequisites

- [deploy-layer-web.md](deploy-layer-web.md) and [deploy-gateway-api.md](deploy-gateway-api.md) applied in `ai-dev`
- Cloudflare tunnel already created; credentials JSON on the server (e.g. `~/.cloudflared/*.json`)
- `APP_URL` / `FRONTEND_URL` = `https://dev.taixingai.com` in dev manifests
- DNS routes for `dev.taixingai.com` and `argocd.taixingai.com` (one-time; see §3)
- [deploy-gitops-argocd.md](deploy-gitops-argocd.md) §1 — Argo CD installed in `argocd` namespace (for `argocd.taixingai.com`)

## 1) Confirm stack

```bash
sudo k3s kubectl -n ai-dev get svc layer-web -o wide
sudo k3s kubectl -n ai-dev get pods -l app=layer-web
sudo k3s kubectl -n ai-dev get pods -l 'app in (layer-gateway-api,layer-orchestrator)'
```

In-cluster sanity (from any pod with curl, or after cloudflared is up):

```bash
sudo k3s kubectl -n ai-dev run curl-test --rm -it --restart=Never \
  --image=curlimages/curl:latest -- \
  curl -sS -o /dev/null -w "%{http_code}\n" http://layer-web.ai-dev.svc.cluster.local:3000/
```

Expect **200**. LAN NodePort (optional):

```bash
curl -sS -o /dev/null -w "%{http_code}\n" http://127.0.0.1:30186/
```

## 2) Create tunnel credentials Secret

**Do not commit** `credentials.json` to git.

```bash
sudo k3s kubectl create secret generic cloudflared-tunnel-credentials -n ai-dev \
  --from-file=credentials.json="$HOME/.cloudflared/ccaafc35-b73f-4df6-ba51-d85b2e5f9bcf.json" \
  --dry-run=client -o yaml | sudo k3s kubectl apply -f -
```

Verify:

```bash
sudo k3s kubectl -n ai-dev get secret cloudflared-tunnel-credentials
```

## 3) DNS route (one-time)

```bash
cloudflared tunnel route dns ccaafc35-b73f-4df6-ba51-d85b2e5f9bcf dev.taixingai.com
cloudflared tunnel route dns ccaafc35-b73f-4df6-ba51-d85b2e5f9bcf argocd.taixingai.com
```

## 4) Apply in-cluster cloudflared

If you previously ran **host** `cloudflared` or `systemd cloudflared`, stop it first (duplicate connectors can cause flaky routing):

```bash
sudo systemctl stop cloudflared 2>/dev/null || true
pkill -f 'cloudflared tunnel' 2>/dev/null || true
```

Deploy:

```bash
cd ~/shared/huntai-k3s
sudo k3s kubectl apply -f manifests/ingress/cloudflared-dev.yaml
sudo k3s kubectl -n ai-dev rollout status deployment/cloudflared --timeout=120s
sudo k3s kubectl -n ai-dev get pods -l app=cloudflared -o wide
sudo k3s kubectl -n ai-dev logs deploy/cloudflared --tail=30
```

Expect logs like `Registered tunnel connection` and no credential errors.

## 5) HTTPS URLs on web + gateway

| Variable | Service | Value |
|----------|---------|--------|
| `APP_URL` | layer-web | `https://dev.taixingai.com` |
| `COOKIE_SECURE` | layer-web | `true` |
| `FRONTEND_URL` | layer-gateway-api | `https://dev.taixingai.com` |

```bash
sudo k3s kubectl apply -f argocd/applications/web-dev.yaml
# Gateway API: managed by Argo CD (gateway-api-dev); push manifest changes or sync in UI
sudo k3s kubectl rollout restart deployment/layer-web deployment/layer-gateway-api -n ai-dev
```

## 6) Supabase Dashboard (manual)

- **Site URL** = `https://dev.taixingai.com`
- **Redirect URLs** = `https://dev.taixingai.com/auth/reset-password`

## 7) Smoke test

```bash
curl -I https://dev.taixingai.com
curl -I https://dev.taixingai.com/chat
```

Browser: `https://dev.taixingai.com/login` → `/chat`.

## 8) Argo CD hostname (`argocd.taixingai.com`)

After [deploy-gitops-argocd.md](deploy-gitops-argocd.md) §1 and DNS route for `argocd.taixingai.com` in §3 above:

```bash
cd ~/shared/huntai-k3s
sudo k3s kubectl apply -f manifests/ingress/cloudflared-dev.yaml
sudo k3s kubectl -n ai-dev rollout restart deploy/cloudflared
sudo k3s kubectl -n ai-dev rollout status deployment/cloudflared --timeout=120s
```

Set Argo CD external URL (fixes UI redirects; one-time):

```bash
sudo k3s kubectl -n argocd patch configmap argocd-cm --type merge \
  -p '{"data":{"url":"https://argocd.taixingai.com"}}'
sudo k3s kubectl -n argocd rollout restart deployment argocd-server
```

Smoke test:

```bash
curl -sS -o /dev/null -w "%{http_code}\n" https://argocd.taixingai.com
```

Browser: [https://argocd.taixingai.com](https://argocd.taixingai.com) — login `admin` + initial password ([deploy-gitops-argocd.md](deploy-gitops-argocd.md) §2). Rotate the default admin password after first login.

Optional later: [Cloudflare Access](https://developers.cloudflare.com/cloudflare-one/policies/access/) policy on `argocd.taixingai.com` (not configured in this pass).

## Alternative: host-run cloudflared (legacy)

Use only for quick debugging without applying the Deployment. On **server-node-1**, cluster DNS from the host may fail; use NodePort:

```yaml
# ~/.cloudflared/config.yml (not in git)
ingress:
  - hostname: dev.taixingai.com
    service: http://127.0.0.1:30186
  - service: http_status:404
```

Run: `cloudflared tunnel run <tunnel-id>`. Do **not** run host and in-cluster connectors at the same time.

## Troubleshooting

| Symptom | Check |
|---------|--------|
| `CreateContainerConfigError` | Secret `cloudflared-tunnel-credentials` §2 |
| Pod CrashLoop | `kubectl logs deploy/cloudflared`; credentials path; tunnel ID in ConfigMap |
| **502** from Cloudflare | Web: `layer-web` Ready; `curl` to `layer-web:3000`. Argo CD: pods in `argocd` Running; `curl -k` from debug pod to `argocd-server:443` |
| **404** hostname | DNS route §3; hostname in ConfigMap ingress (`dev.taixingai.com` or `argocd.taixingai.com`) |
| Argo CD x509 in cloudflared logs | `originRequest.noTLSVerify: true` under `argocd.taixingai.com` ingress rule |
| Argo CD redirect loop / wrong URL | `argocd-cm` `url: https://argocd.taixingai.com` §8 |
| Duplicate / flaky tunnel | Only one connector: stop host systemd **or** scale in-cluster to 0 |
| Login OK, chat **401** | Gateway secrets; `APP_URL` / `FRONTEND_URL` HTTPS |
| Wrong reset link | Supabase Site URL |

## Prod (later)

Copy pattern to `manifests/ingress/cloudflared-prod.yaml` in `ai-prod`, separate tunnel Secret and hostname (e.g. `taixingai.com`). Not in this pass.
