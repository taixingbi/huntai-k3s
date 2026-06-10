# Deploy layer-web (Next.js, dev)

Service image: [ghcr.io/taixingbi/layer-web-v1](https://github.com/taixingbi/layer-web-v1/pkgs/container/layer-web-v1) — source: [layer-web-v1](https://github.com/taixingbi/layer-web-v1). CI publishes `latest` on push to `main` ([Actions](https://github.com/taixingbi/layer-web-v1/actions) → **Push to GHCR**).

Next.js 15 (App Router) chat UI + BFF that talks only to [layer-gateway-api-v1](https://github.com/taixingbi/layer-gateway-api-v1) (no direct orchestrator access). **Public dev URL:** [https://dev.taixingai.com](https://dev.taixingai.com) via in-cluster [cloudflared](deploy-dev-cloudflare-tunnel.md) → `layer-web:3000`. LAN NodePort **`30186`**; pods listen on **3000** ([Dockerfile](https://github.com/taixingbi/layer-web-v1/blob/main/Dockerfile)). In-cluster: `http://layer-web:3000`.

Upstream: [README](https://github.com/taixingbi/layer-web-v1/blob/main/README.md), [docs/design.md](https://github.com/taixingbi/layer-web-v1/blob/main/docs/design.md), [docs/auth-design.md](https://github.com/taixingbi/layer-web-v1/blob/main/docs/auth-design.md).

**Browser → BFF → gateway**

| Browser (web origin) | BFF proxies to gateway |
|----------------------|-------------------------|
| `POST /api/v1/chat` | `POST /v1/chat` |
| `POST /api/v1/feedback` | `POST /v1/feedback` |
| `GET /api/v1/conversations` | `GET /v1/conversations` |
| `GET /api/v1/conversations/{id}/messages` | conversation messages |
| `GET` / `PATCH /api/v1/profile` | `GET` / `PATCH /profile` |

BFF translates gateway SSE (`meta`, `rewrite`, `token`, `done`, `error`) into client events (`status`, `rewrite`, `result_chunk`, `stream_end`, `error`).

## Prerequisites

- **layer-gateway-api** in `ai-dev` — [deploy-gateway-api.md](deploy-gateway-api.md) (`http://layer-gateway-api:8000` or NodePort `30185`). Web sets `GATEWAY_BASE_URL=http://layer-gateway-api:8000` (in-cluster, not NodePort).
- Gateway **`FRONTEND_URL`** must equal web **`APP_URL`** (`https://dev.taixingai.com` when using the tunnel; LAN debug `http://192.168.86.179:30186`) and Supabase **Site URL** / reset redirect.
- Supabase keys on the gateway only (`layer-gateway-api-secrets`); web has no Supabase secret.
- Port map: [port.md](port.md) (`30186` dev).

## 1) Configure env (optional)

Defaults in [manifests/web/base/deployment.yaml](../manifests/web/base/deployment.yaml). Full list: upstream [`.env.example`](https://github.com/taixingbi/layer-web-v1/blob/main/.env.example), [`app/lib/config.ts`](https://github.com/taixingbi/layer-web-v1/blob/main/app/lib/config.ts).

| Variable | Dev manifest | Notes |
|----------|----------------|--------|
| `APP_URL` | `https://dev.taixingai.com` | Public URL; match gateway `FRONTEND_URL` + Supabase Site URL |
| `GATEWAY_BASE_URL` | `http://layer-gateway-api:8000` | In-cluster gateway |
| `COOKIE_SECURE` | `true` | Required for HTTPS via Cloudflare Tunnel |
| `AUTH_SESSION_MAX_AGE_SECONDS` | `3600` | httpOnly `layer_access_token` after `/login`; align with gateway `JWT_EXPIRY_SECONDS` |
| `WEB_SERVICE_NAME` | `layer-web` | JSON log `service` field (upstream default: `huntai-web`) |

**Admin dashboard (`/admin`)** — requires admin role on user profile. Non-secret env is in [manifests/web/base/deployment.yaml](../manifests/web/base/deployment.yaml); Supabase service role comes from the same Secret as gateway-api (`layer-gateway-api-secrets` in dev, `layer-ai-prod-secrets` in prod).

| Variable | Dev manifest | Notes |
|----------|----------------|--------|
| `ORCHESTRATOR_BASE_URL` | `http://layer-orchestrator:8000` | Health probe |
| `RAG_QUERY_BASE_URL` | `http://layer-rag-query:8000` | |
| `INFERENCE_GATEWAY_BASE_URL` | `http://layer-gateway-inference:8000` | Prod overlay: `*.ai-dev.svc.cluster.local` |
| `EMBED_GATEWAY_BASE_URL` | `http://layer-gateway-embedding:8000` | |
| `RERANKER_GATEWAY_BASE_URL` | `http://layer-gateway-reranker:8000` | |
| `QDRANT_BASE_URL` | `http://qdrant:6333` | Probe uses `/healthz` |
| `REDIS_URL` | `redis://redis:6379/0` | Admin **Redis** health (RESP PING); RAG query cache |
| `PROMETHEUS_URL` | `http://prometheus.monitoring.svc.cluster.local:9090` | KPI + GPU metrics |
| `SUPABASE_URL` / `SUPABASE_SERVICE_KEY` | from gateway Secret | Recent requests + feedback + **Supabase health** |

Supabase health probes `GET /auth/v1/health` and `GET /rest/v1/profiles?limit=1` (Postgres + Auth). Redis health uses a TCP `PING` against `REDIS_URL` (deployed with the RAG overlay in `ai-dev`). Orchestrator health uses an 8s probe timeout because `/ready` runs LLM + RAG dependency checks.
| `ADMIN_INFERENCE_MODEL` | `qwen2.5-7b` | Chat vLLM display label |
| `ADMIN_EMBEDDING_MODEL` | `BAAI/bge-m3` | Embedding vLLM display label |
| `ADMIN_RERANKER_MODEL` | `BAAI/bge-reranker-v2-m3` | Reranker vLLM display label |
| `ADMIN_ROUTER_VERSION` | `router-v2` | Display label |

Optional: `ADMIN_ROUTER_ACCURACY`, `ADMIN_ROUTER_EVALUATED_AT` (golden eval snapshot).

After manifest change: sync **`web-dev`** in Argo CD (or `kubectl rollout restart deployment/layer-web -n ai-dev`). KPI cards stay empty until Prometheus has scrape data and chat traffic exists.

Optional (not in manifest): `GATEWAY_BEARER_TOKEN` (service/stub fallback when browser sends no `Authorization`); `AUTH_SIGNUP_URL` (external IdP link on `/signup`).

**Auth flow:** `/login` → BFF sets httpOnly **`layer_access_token`** → BFF forwards `Authorization: Bearer` to gateway. Per-user JWT in production; do not rely on a shared `GATEWAY_BEARER_TOKEN` for all users.

## 2) Deploy via Argo CD (GitOps)

```bash
# optional: preload image after upstream CI
sudo k3s ctr images pull ghcr.io/taixingbi/layer-web-v1:latest

# GitOps via app-of-apps (deploy-gitops-argocd.md)
sudo k3s kubectl get application web-dev -n argocd

sudo k3s kubectl get pods,svc -n ai-dev -l app=layer-web -o wide
sudo k3s kubectl get svc -A -o wide | grep 30186
```

If the pod does not start:

```bash
sudo k3s kubectl describe pod -n ai-dev -l app=layer-web
sudo k3s kubectl logs -n ai-dev deploy/layer-web --tail=50
```

After changing `APP_URL` for the tunnel, also apply [deploy-gateway-api.md](deploy-gateway-api.md) (`FRONTEND_URL`) and follow [deploy-dev-cloudflare-tunnel.md](deploy-dev-cloudflare-tunnel.md) §5–§6.

## 3) Smoke tests

Public URL: **https://dev.taixingai.com** (requires [Cloudflare Tunnel](deploy-dev-cloudflare-tunnel.md)). LAN: `192.168.86.179:30186`.

```bash
export WEB_URL='https://dev.taixingai.com'
# LAN: export WEB_URL='http://192.168.86.179:30186'
```

### 3.0 Static pages

```bash
curl -sS -o /dev/null -w "%{http_code}\n" "${WEB_URL}/"
curl -sS -o /dev/null -w "%{http_code}\n" "${WEB_URL}/chat"
curl -sS -o /dev/null -w "%{http_code}\n" "${WEB_URL}/login"
```

**Pass:** all **200**.

### 3.1 Browser (full stack)

1. Open `http://192.168.86.179:30186/login` — sign in (email/password via gateway Supabase).
2. Open `http://192.168.86.179:30186/chat` — send a message; answer streams in.
3. Sidebar lists conversations when Supabase history is enabled on the gateway.
4. Thumbs up/down after the assistant message is saved (needs `message_id` + `conversation_id` from the chat response).

### 3.2 BFF chat SSE (`curl -N`)

Requires a valid bearer (from gateway `POST /v1/auth/login`, or `sessionStorage.layer_bearer_token` in the browser). Example with a token:

```bash
export ACCESS_TOKEN='eyJ...'   # from gateway login

curl -N -sS -X POST "${WEB_URL}/api/v1/chat" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -H "X-Session-Id: curl-web-sess-1" \
  -H "X-Request-Id: curl-web-req-1" \
  -d '{"message":"what is Taixing US visa status?"}'
```

**Pass:** BFF SSE lines with `event: status`, optional `event: rewrite`, `event: result_chunk` (…), `event: stream_end` (maps from gateway `event: answer_delta`).

Compare with gateway-direct smoke: [deploy-gateway-api.md §3.3](deploy-gateway-api.md) (`POST /v1/chat` on port **30185**).

### 3.3 BFF feedback (requires ids from chat)

```bash
curl -sS -X POST "${WEB_URL}/api/v1/feedback" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "message_id": "<assistant_message_uuid>",
    "conversation_id": "<conversation_uuid>",
    "rating": "thumbs_up"
  }' | jq .
```

**Pass:** **200** when gateway Supabase is configured; **400** if `message_id` or `conversation_id` missing.

### 3.4 Checklist

| Step | Target | Expect |
|------|--------|--------|
| 1 | `GET /`, `/chat`, `/login` | **200** |
| 2 | Browser `/login` → `/chat` | Streamed answer |
| 3 | `POST /api/v1/chat` (curl + bearer) | BFF SSE `result_chunk` → `stream_end` |
| 4 | `POST /api/v1/feedback` | **200** with valid message/conversation ids |
| 5 | Gateway `30185` healthy | [deploy-gateway-api.md](deploy-gateway-api.md) §3 |

## 4) Observability

Structured JSON logs from BFF routes (`logWebEvent` in [`app/lib/server-log.ts`](https://github.com/taixingbi/layer-web-v1/blob/main/app/lib/server-log.ts)). No Prometheus `/metrics` on this image yet.

## Troubleshooting

| Symptom | Check |
|---------|--------|
| Login works but chat **401** | Gateway Supabase/JWKS; cookie `layer_access_token`; `COOKIE_SECURE=false` on HTTP |
| Chat works but feedback **400** | Wait for assistant save; body must include `message_id` + `conversation_id` |
| Empty conversation sidebar | Gateway Supabase + chat persistence; sign in as same user |
| Password reset link wrong | `APP_URL` = gateway `FRONTEND_URL` = Supabase Site URL |
| Stale UI | Pull `taixingbi/layer-web-v1:latest` after [CI](https://github.com/taixingbi/layer-web-v1/actions); hard-refresh browser |
| BFF cannot reach gateway | `GATEWAY_BASE_URL=http://layer-gateway-api:8000`; gateway pod ready |

NodePort:

- dev: `30186`
