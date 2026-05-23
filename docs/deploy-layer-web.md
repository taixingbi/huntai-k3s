# Deploy layer-web (Next.js, dev)

Service image: [taixingbi/layer-web-v1](https://hub.docker.com/r/taixingbi/layer-web-v1) — source: [layer-web-v1](https://github.com/taixingbi/layer-web-v1)

Next.js 15 (App Router) chat UI + BFF routes that proxy to [layer-gateway-api-v1](https://github.com/taixingbi/layer-gateway-api-v1) (`POST /api/chat`, `POST /api/feedback`). The dev manifest exposes the app on NodePort **`30186`**; pods listen on **3000** (see [Dockerfile](https://github.com/taixingbi/layer-web-v1/blob/main/Dockerfile)). In-cluster callers use `http://layer-web:3000` in `ai-dev`.

## Prerequisites

- **layer-gateway-api** running in `ai-dev` (`http://layer-gateway-api:8000` or NodePort `30185`); see [deploy-gateway-api.md](deploy-gateway-api.md). The web pod sets `GATEWAY_BASE_URL=http://layer-gateway-api:8000` so the BFF reaches the gateway inside the cluster.
- Port map: `docs/port.md` (`30186` dev).

## 1) Configure env (optional)

Defaults are in [manifests/web/layer-web-dev.yaml](manifests/web/layer-web-dev.yaml):

| Variable | Dev value | Notes |
|----------|-----------|--------|
| `APP_URL` | `http://192.168.86.179:30186` | Must match gateway `FRONTEND_URL` and Supabase **Site URL** / reset redirect |
| `GATEWAY_BASE_URL` | `http://layer-gateway-api:8000` | In-cluster gateway (not NodePort `30185`) |
| `AUTH_SESSION_MAX_AGE_SECONDS` | `3600` | Align with gateway `JWT_EXPIRY_SECONDS` |
| `WEB_SERVICE_NAME` | `layer-web` | JSON log `service` field |

Supabase keys live on **layer-gateway-api** only (`layer-gateway-api-secrets`); see [deploy-gateway-api.md](deploy-gateway-api.md). Chat and auth use `/login` → httpOnly cookie → BFF `Authorization` to the gateway.

Runtime variables: upstream [README](https://github.com/taixingbi/layer-web-v1/blob/main/README.md) and `app/lib/config.ts`.

## 2) Apply manifests

```bash
# optional: preload image on the node (requires image published to Docker Hub or your registry)
sudo k3s ctr images pull docker.io/taixingbi/layer-web-v1:latest

sudo k3s kubectl apply -f manifests/web/layer-web-dev.yaml
sudo k3s kubectl rollout restart deployment/layer-web -n ai-dev
sudo k3s kubectl rollout status deployment/layer-web -n ai-dev
sudo k3s kubectl get pods,svc -n ai-dev -l app=layer-web -o wide
sudo k3s kubectl get svc -A -o wide | grep 30186
```

## 3) Smoke tests

From a host that can reach NodePort `30186` (adjust IP if your server differs; default LAN control plane is `192.168.86.179`).

Home should return HTTP 200:

```bash
curl -sS -o /dev/null -w "%{http_code}\n" http://192.168.86.179:30186/
echo
```

Chat UI (upstream README):

```bash
curl -sS -o /dev/null -w "%{http_code}\n" http://192.168.86.179:30186/chat
echo
```

Open in a browser: `http://192.168.86.179:30186/chat` — sign in at `/login` first; the BFF forwards the session cookie as `Authorization: Bearer` to the gateway.

## 4) Observability

This image does not expose Prometheus `/metrics` yet. When it does, add a scrape job similar to `layer-gateway-api` in [manifests/observability/prometheus-grafana.yaml](manifests/observability/prometheus-grafana.yaml).

NodePort:

- dev: `30186`
