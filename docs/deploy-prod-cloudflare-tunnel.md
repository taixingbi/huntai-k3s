# Prod public URL — Cloudflare Tunnel (`ai-prod`)

Expose prod web over HTTPS without inbound ports:

- **`taixingai.com`** — HuntAI web UI (`layer-web.ai-prod:3000`)
- **`www.taixingai.com`** — same backend (redirect policy optional in Cloudflare dashboard)

Use a **separate** tunnel from dev (`ccaafc35-…` in `ai-dev`). Do not share credentials JSON between namespaces.

Manifest: [`manifests/ingress/overlays/prod/cloudflared.yaml`](../manifests/ingress/overlays/prod/cloudflared.yaml). Argo CD app: **`cloudflared-prod`** (manual sync, wave 12 — after `web-prod`).

Prerequisites: [deploy-prod.md](deploy-prod.md) — `layer-ai-prod-secrets`, synced **rag → orchestrator → gateway-api → web**.

## 1) Create prod tunnel (Cloudflare Zero Trust)

On the control plane (e.g. `server-node-1`):

```bash
cloudflared tunnel create huntai-prod
# Note the tunnel UUID; credentials land in ~/.cloudflared/<UUID>.json
```

## 2) Set tunnel UUID in Git

Edit `manifests/ingress/overlays/prod/cloudflared.yaml` — replace `REPLACE_PROD_TUNNEL_UUID` with your UUID. Commit and push (or patch locally before first sync).

## 3) Credentials Secret

```bash
PROD_UUID='YOUR_TUNNEL_UUID'

sudo k3s kubectl create secret generic cloudflared-tunnel-credentials -n ai-prod \
  --from-file=credentials.json="$HOME/.cloudflared/${PROD_UUID}.json" \
  --dry-run=client -o yaml | sudo k3s kubectl apply -f -

sudo k3s kubectl -n ai-prod get secret cloudflared-tunnel-credentials
```

## 4) DNS routes

```bash
cloudflared tunnel route dns "$PROD_UUID" taixingai.com
cloudflared tunnel route dns "$PROD_UUID" www.taixingai.com
```

## 5) Sync tunnel Deployment

```bash
# Register app (included in scripts/deploy-ai-prod.sh)
sudo k3s kubectl apply -f argocd/applications/cloudflared-prod.yaml

# Argo UI: Sync cloudflared-prod — or:
argocd app sync cloudflared-prod

sudo k3s kubectl -n ai-prod rollout status deployment/cloudflared --timeout=120s
sudo k3s kubectl -n ai-prod logs deploy/cloudflared --tail=30
```

## 6) Supabase / app URLs

Match prod overlays:

| Var | Service | Value |
|-----|---------|--------|
| `APP_URL` | layer-web | `https://taixingai.com` |
| `FRONTEND_URL` | layer-gateway-api | `https://taixingai.com` |

Prod Supabase project: **Site URL** = `https://taixingai.com`, redirect URLs for auth flows.

## 7) Verify

```bash
curl -I https://taixingai.com
curl -I https://www.taixingai.com
```

In-cluster (before tunnel):

```bash
sudo k3s kubectl -n ai-prod run curl-test --rm -it --restart=Never \
  --image=curlimages/curl:latest -- \
  curl -sS -o /dev/null -w "%{http_code}\n" http://layer-web.ai-prod.svc.cluster.local:3000/
```

## Troubleshooting

| Symptom | Check |
|---------|--------|
| `CreateContainerConfigError` | Secret `cloudflared-tunnel-credentials` in `ai-prod` |
| CrashLoop / invalid tunnel | UUID in ConfigMap matches credentials JSON filename |
| **404** hostname | `tunnel route dns` for apex and `www` |
| Placeholder still in ConfigMap | `REPLACE_PROD_TUNNEL_UUID` not replaced |
| Duplicate connectors | Only one prod `cloudflared` Deployment; stop host systemd tunnel for prod if any |

Dev tunnel doc: [deploy-dev-cloudflare-tunnel.md](deploy-dev-cloudflare-tunnel.md).
