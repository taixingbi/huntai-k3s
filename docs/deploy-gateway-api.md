# Deploy Gateway API (dev)

Service image: [taixingbi/layer-gateway-api-v1](https://hub.docker.com/r/taixingbi/layer-gateway-api-v1) — source: [layer-gateway-api-v1](https://github.com/taixingbi/layer-gateway-api-v1)

The dev manifest exposes the gateway on NodePort **`30185`** and ClusterIP port **`8000`**. In-cluster callers use `http://layer-gateway-api:8000` in `ai-dev`. Orchestrator remains NodePort **`30184`** (see `docs/port.md`).

FastAPI edge between Next.js and orchestration: validates auth (Supabase or JWKS), normalizes chat, propagates tracing headers, calls orchestrator with timeout/retry (`flat_headers` → `X-User-*` upstream). Upstream curl reference: [`docs/smoke-test.md`](https://github.com/taixingbi/layer-gateway-api-v1/blob/main/docs/smoke-test.md).

Key endpoints:

- `GET /health` — liveness (no auth)
- `GET /ready` — readiness (orchestrator probe; **503** if upstream unhealthy)
- `GET /metrics` — Prometheus (no auth)
- `POST /auth/login`, `POST /auth/signup`, … — Supabase Auth helpers (no bearer on login; requires `SUPABASE_*` in gateway config)
- `POST /api/chat` — JSON or SSE (`Accept: text/event-stream` or `"stream": true`)
- `POST /api/feedback` — when `ORCHESTRATOR_CONTRACT=flat_headers` (manifest default); **501** in `gateway_json` mode

## Prerequisites

- **Orchestrator** in `ai-dev` (`layer-orchestrator:8000` or NodePort `30184`); see [deploy-orchestrator.md](deploy-orchestrator.md). If orchestrator is down, `GET /ready` returns **503** unless you set `ORCHESTRATOR_READINESS_PROBE_ENABLED=false` in the manifest.
- **Auth secret** `layer-gateway-api-secrets` in `ai-dev` (see below). Pods stay `CreateContainerConfigError` until it exists.
- Port map: `docs/port.md` (`30185` dev).
- Optional UI: [deploy-layer-web.md](deploy-layer-web.md) (NodePort `30186`; BFF proxies to this gateway).

## 1) Create auth secrets and review env

The dev manifest uses `envFrom.secretRef.name=layer-gateway-api-secrets`. Non-secret env is in [manifests/gateway/layer-gateway-api-dev.yaml](../manifests/gateway/layer-gateway-api-dev.yaml). Full variable list: upstream [`.env.example`](https://github.com/taixingbi/layer-gateway-api-v1/blob/main/.env.example).

Manifest defaults (edit YAML to change):

| Variable | Dev value |
|----------|-----------|
| `ORCHESTRATOR_BASE_URL` | `http://layer-orchestrator:8000` |
| `ORCHESTRATOR_CHAT_PATH` | `/orchestrator/answer` |
| `ORCHESTRATOR_CONTRACT` | `flat_headers` |
| `FRONTEND_URL` | `http://192.168.86.179:30186` (layer-web NodePort) |
| `MAX_INFLIGHT_REQUESTS` | `100` |

**Supabase (recommended)** — Supabase Dashboard → Project Settings → API:

```bash
mkdir -p ~/.secrets
chmod 700 ~/.secrets
printf '%s' 'https://YOUR_PROJECT.supabase.co' > ~/.secrets/supabase-url
printf '%s' 'YOUR_ANON_KEY' > ~/.secrets/supabase-anon-key
printf '%s' 'YOUR_SERVICE_ROLE_KEY' > ~/.secrets/supabase-service-key
chmod 600 ~/.secrets/supabase-url ~/.secrets/supabase-anon-key ~/.secrets/supabase-service-key

sudo k3s kubectl create secret generic layer-gateway-api-secrets -n ai-dev \
  --from-file=SUPABASE_URL="$HOME/.secrets/supabase-url" \
  --from-file=SUPABASE_ANON_KEY="$HOME/.secrets/supabase-anon-key" \
  --from-file=SUPABASE_SERVICE_KEY="$HOME/.secrets/supabase-service-key" \
  --dry-run=client -o yaml | sudo k3s kubectl apply -f -
```

Use the **anon public** key for `SUPABASE_ANON_KEY` and the **service_role** key (server-only) for `SUPABASE_SERVICE_KEY` — needed for `profiles` lookup, username login, and RLS bypass per upstream `.env.example`.

**JWKS fallback** (Secret must not include `SUPABASE_*`; gateway validates OIDC access tokens):

```bash
sudo k3s kubectl create secret generic layer-gateway-api-secrets -n ai-dev \
  --from-literal=AUTH_JWT_ISSUER='https://your-idp.example/' \
  --from-literal=AUTH_JWT_AUDIENCE='api://your-resource-id' \
  --from-literal=AUTH_JWT_JWKS_URL='https://your-idp.example/.well-known/jwks.json' \
  --dry-run=client -o yaml | sudo k3s kubectl apply -f -
```

Verify keys are mounted (names only, not values):

```bash
sudo k3s kubectl get secret layer-gateway-api-secrets -n ai-dev -o jsonpath='{.data}' | jq 'keys'
```

## 2) Apply manifests

```bash
# optional: preload image on the node
sudo k3s ctr images pull docker.io/taixingbi/layer-gateway-api-v1:latest

sudo k3s kubectl apply -f manifests/gateway/layer-gateway-api-dev.yaml
sudo k3s kubectl rollout restart deployment/layer-gateway-api -n ai-dev
sudo k3s kubectl rollout status deployment/layer-gateway-api -n ai-dev
sudo k3s kubectl get pods,svc -n ai-dev -l app=layer-gateway-api -o wide
sudo k3s kubectl get svc -A -o wide | grep 30185
```

If the pod does not start:

```bash
sudo k3s kubectl describe pod -n ai-dev -l app=layer-gateway-api
sudo k3s kubectl logs -n ai-dev deploy/layer-gateway-api --tail=50
```

## 3) Smoke tests

From a host that can reach the dev NodePort (default control plane `192.168.86.179`). `jq` is optional.

```bash
export GATEWAY_URL='http://192.168.86.179:30185'
```

Protected routes need `Authorization: Bearer <access_token>` (Supabase session token or JWKS-valid OIDC JWT). With Supabase configured, obtain a token via gateway login:

```bash
curl -sS -X POST "${GATEWAY_URL}/auth/login" \
  -H 'Content-Type: application/json' \
  -d '{"email":"you@example.com","password":"YOUR_PASSWORD"}' | jq .

export ACCESS_TOKEN='eyJ...'   # .access_token from the response
```

Correlation: use **`X-Request-Id`** / **`X-Trace-Id`** (optional; gateway mints if omitted) and **`X-Session-Id`** (optional; gateway mints `sess_…` if omitted). Do **not** put `session_id`, `request_id`, or `trace_id` in the JSON body.

### Probes and metrics (no auth)

```bash
curl -sS "${GATEWAY_URL}/health" | jq .
echo
curl -sS "${GATEWAY_URL}/ready" | jq .
echo
curl -sS "${GATEWAY_URL}/metrics" | head -n 40
echo
```

### Chat — non-stream JSON

```bash
curl -sS -X POST "${GATEWAY_URL}/api/chat" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -H "X-Session-Id: smoke-sess-001" \
  -H "X-Request-Id: smoke-req-001" \
  -H "X-Trace-Id: smoke-trace-001" \
  -d '{
    "conversation_id": "smoke-conv-001",
    "message": "What is Taixing US visa status?",
    "metadata": { "page": "/support", "user_agent": "curl" }
  }' | jq .
echo
```

Expect `200`, `"status": "success"`, echoed ids, and no `error` key.

### Chat — with history

```bash
curl -sS -X POST "${GATEWAY_URL}/api/chat" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "message": "what is Taixing Bi visa status in us?",
    "conversation_id": "conv-smoke-1",
    "history": [
      {"role": "user", "content": "What is Taixing Bi US visa status?"},
      {"role": "assistant", "content": "Taixing has H4 EAD and does not need sponsorship."}
    ],
    "metadata": { "page": "/support", "user_agent": "curl" }
  }' | jq .
echo
```

### Chat — SSE

Use `Accept: text/event-stream` or `"stream": true` in the body:

```bash
curl -N -sS -X POST "${GATEWAY_URL}/api/chat" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -H "Accept: text/event-stream" \
  -H "X-Session-Id: smoke-sess-002" \
  -H "X-Request-Id: smoke-req-002" \
  -H "X-Trace-Id: smoke-trace-002" \
  -d '{
    "conversation_id": "conv-smoke-2",
    "message": "what is Taixing Bi visa status in us",
    "history": [
      {"role": "user", "content": "What is Taixing Bi US visa status?"},
      {"role": "assistant", "content": "Taixing has H4 EAD and does not need sponsorship."}
    ],
    "metadata": { "page": "/support", "user_agent": "curl" },
    "stream": true
  }'
```

Expect `event: meta`, optional `event: rewrite`, one or more `event: token`, then `event: done`.

### Auth failure (expect 401)

```bash
curl -sS -o /dev/stderr -w "%{http_code}\n" -X POST "${GATEWAY_URL}/api/chat" \
  -H "Content-Type: application/json" \
  -d '{"message":"should fail"}'
```

### Feedback (`flat_headers` only)

Use the same `trace_id` / `request_id` as the chat call above.

**Thumbs up:**

```bash
curl -sS -X POST "${GATEWAY_URL}/api/feedback" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "trace_id": "smoke-trace-001",
    "request_id": "smoke-req-001",
    "rating": "thumbs_up"
  }' | jq .
echo
```

**Thumbs down** (optional fields):

```bash
curl -sS -X POST "${GATEWAY_URL}/api/feedback" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "trace_id": "smoke-trace-001",
    "rating": "thumbs_down",
    "feedback_type": "not_factual",
    "comment": "Smoke test comment",
    "question": "What is Taixing US visa status?"
  }' | jq .
echo
```

### Full stack (layer-web BFF)

The Next.js app on NodePort **`30186`** exposes `POST /api/chat` and translates gateway SSE for the browser. Smoke via [deploy-layer-web.md](deploy-layer-web.md) (`/login` or `Authorization: Bearer`); do not curl the gateway with `demo-token` unless it is a real JWT.

### Checklist

| Step | Endpoint | Expect |
|------|----------|--------|
| 1 | `GET /health` | `200`, `"status":"ok"` |
| 2 | `GET /ready` | `200` if orchestrator healthy, else `503` |
| 3 | `GET /metrics` | `200`, body contains `gateway_requests_total` |
| 4 | `POST /api/chat` (JSON) | `200`, success payload |
| 5 | `POST /api/chat` with `"stream": true` | SSE `meta` → optional `rewrite` → `token` (…) → `done` |
| 6 | `POST /api/feedback` | `200`/`204`/`4xx` from upstream; **501** if `ORCHESTRATOR_CONTRACT=gateway_json` |

## 4) Observability

After changing scrape rules, reload Prometheus:

```bash
sudo k3s kubectl apply -f manifests/observability/prometheus-grafana.yaml
sudo k3s kubectl rollout restart deployment/prometheus -n monitoring
```

Prometheus job `layer-gateway-api` scrapes Service `layer-gateway-api` in `ai-dev` at `/metrics` (see [manifests/observability/prometheus-grafana.yaml](../manifests/observability/prometheus-grafana.yaml)).

NodePort:

- dev: `30185`
