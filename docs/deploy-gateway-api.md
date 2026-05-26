# Deploy Gateway API (dev)

Service image: [taixingbi/layer-gateway-api-v1](https://hub.docker.com/r/taixingbi/layer-gateway-api-v1) — source: [layer-gateway-api-v1](https://github.com/taixingbi/layer-gateway-api-v1). CI publishes `latest` on push to `main` ([Actions](https://github.com/taixingbi/layer-gateway-api-v1/actions) → **Push to Docker Hub** → `docker.io/taixingbi/layer-gateway-api-v1:latest`).

The dev manifest exposes the gateway on NodePort **`30185`** and ClusterIP port **`8000`**. In-cluster callers use `http://layer-gateway-api:8000` in `ai-dev`. Orchestrator is NodePort **`30184`** (see [port.md](port.md)).

FastAPI edge between Next.js and orchestration: validates auth at the edge (Supabase or JWKS), normalizes chat, persists messages to Supabase when configured, propagates tracing headers, calls orchestrator with timeout/retry. Dev uses **`ORCHESTRATOR_CONTRACT=flat_headers`** (forwards `X-User-*` to orchestrator). Upstream references: [`docs/smoke-test.md`](https://github.com/taixingbi/layer-gateway-api-v1/blob/main/docs/smoke-test.md), [`docs/design.md`](https://github.com/taixingbi/layer-gateway-api-v1/blob/main/docs/design.md), [`README.md`](https://github.com/taixingbi/layer-gateway-api-v1/blob/main/README.md).

Key endpoints:

- `GET /health` — liveness (no auth)
- `GET /ready` — readiness (`GET` orchestrator `ORCHESTRATOR_READINESS_PATH`; **503** if probe fails)
- `GET /metrics` — Prometheus (no auth)
- `POST /v1/auth/login`, `POST /v1/auth/signup`, `POST /v1/auth/refresh`, password-reset routes — Supabase Auth (no bearer on login; requires `SUPABASE_*`)
- `GET /profile`, `PATCH /profile` — user profile (`profiles` table)
- `GET /v1/conversations` — conversation list (Supabase)
- `POST /v1/chat` — JSON or SSE (`Accept: text/event-stream` or `"stream": true`)
- `POST /v1/feedback` — Supabase `message_feedback` only (`message_id` + `conversation_id` from prior chat; **not** forwarded to orchestrator)

**Correlation:** `X-Request-Id`, `X-Trace-Id`, `X-Session-Id` on **headers** only (gateway mints missing ids; JSON body fields `request_id` / `session_id` / `trace_id` are **rejected**). Optional **`conversation_id`** in the chat JSON body.

**`latency_ms`:** Non-stream JSON and SSE `event: done` include gateway phases (`total`, `auth`, `validation`, `storage`, `orchestrator`) plus optional nested orchestrator **`usage`**.

**SSE (`POST /v1/chat`):** `event: meta` → optional `event: rewrite` → `event: token` (…) → `event: done` (or `event: error`). With `flat_headers`, citations / follow-ups on upstream SSE may be aggregated into `done`; if the stream lacks them, the gateway may issue one supplemental non-stream orchestrator call to fill `done` metadata.

## Prerequisites

- **Orchestrator** in `ai-dev` — [deploy-orchestrator.md](deploy-orchestrator.md) (`layer-orchestrator:8000` or NodePort `30184`). Gateway calls **`POST /v1/orchestrator/answer`** (`ORCHESTRATOR_CHAT_PATH` in manifest).
- **Auth secret** `layer-gateway-api-secrets` in `ai-dev` (§1). Pods stay `CreateContainerConfigError` until it exists.
- Port map: [port.md](port.md) (`30185` dev).
- Optional UI: [deploy-layer-web.md](deploy-layer-web.md) — public [https://dev.taixingai.com](https://dev.taixingai.com) ([deploy-dev-cloudflare-tunnel.md](deploy-dev-cloudflare-tunnel.md)) or LAN NodePort `30186`.

## 1) Create auth secrets and review env

The dev manifest uses `envFrom.secretRef.name=layer-gateway-api-secrets`. Non-secret env is in [manifests/gateway-api/base/deployment.yaml](../manifests/gateway-api/base/deployment.yaml). Full list: upstream [`.env.example`](https://github.com/taixingbi/layer-gateway-api-v1/blob/main/.env.example) and [`app/core/config.py`](https://github.com/taixingbi/layer-gateway-api-v1/blob/main/app/core/config.py).

| Variable | Dev manifest |
|----------|----------------|
| `ORCHESTRATOR_BASE_URL` | `http://layer-orchestrator:8000` |
| `ORCHESTRATOR_CHAT_PATH` | `/v1/orchestrator/answer` |
| `ORCHESTRATOR_CONTRACT` | `flat_headers` |
| `CHAT_ASSISTANT_MODEL` | `qwen2.5-7b` |
| `ORCHESTRATOR_TIMEOUT_MS` | `15000` |
| `ORCHESTRATOR_RETRY_MAX_ATTEMPTS` | `2` |
| `ORCHESTRATOR_READINESS_PROBE_ENABLED` | `true` |
| `FRONTEND_URL` | `https://dev.taixingai.com` |
| `MAX_INFLIGHT_REQUESTS` | `100` |
| `JWT_EXPIRY_SECONDS` | `3600` |
| `CHAT_MESSAGE_MAX_LENGTH` | `4000` |

Alternate contract (not in dev manifest): `ORCHESTRATOR_CONTRACT=gateway_json` with nested JSON to orchestrator — see upstream README.

**Supabase (recommended)** — Dashboard → Project Settings → API; Authentication → URL configuration:

- **Site URL** = `FRONTEND_URL` (e.g. `https://dev.taixingai.com`)
- **Redirect URLs** = `{FRONTEND_URL}/auth/reset-password`

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

Use the **anon public** key for `SUPABASE_ANON_KEY` and the **service_role** key for `SUPABASE_SERVICE_KEY` (username→email lookup, chat history, `message_feedback`). Optional SQL: upstream [`sql/username_login.sql`](https://github.com/taixingbi/layer-gateway-api-v1/tree/main/sql), [`sql/message_feedback_feedback_reason_constraint.sql`](https://github.com/taixingbi/layer-gateway-api-v1/tree/main/sql).

**JWKS fallback** (Secret must not include `SUPABASE_*`):

```bash
sudo k3s kubectl create secret generic layer-gateway-api-secrets -n ai-dev \
  --from-literal=AUTH_JWT_ISSUER='https://your-idp.example/' \
  --from-literal=AUTH_JWT_AUDIENCE='api://your-resource-id' \
  --from-literal=AUTH_JWT_JWKS_URL='https://your-idp.example/.well-known/jwks.json' \
  --dry-run=client -o yaml | sudo k3s kubectl apply -f -
```

Verify secret keys (names only):

```bash
sudo k3s kubectl get secret layer-gateway-api-secrets -n ai-dev -o jsonpath='{.data}' | jq 'keys'
```

## 2) Deploy via GitOps (Argo CD)

Gateway API dev is managed by Argo CD Application `gateway-api-dev`. See [deploy-gitops-argocd.md](deploy-gitops-argocd.md) for install, bootstrap, and verify steps.

After changing manifests under `manifests/gateway-api/`, commit and push to `main` — Argo CD syncs automatically.

```bash
# optional: preload image after upstream CI (https://github.com/taixingbi/layer-gateway-api-v1/actions)
sudo k3s ctr images pull docker.io/taixingbi/layer-gateway-api-v1:latest

sudo k3s kubectl get application gateway-api-dev -n argocd
sudo k3s kubectl get pods,svc -n ai-dev -l app=layer-gateway-api -o wide
sudo k3s kubectl get svc -A -o wide | grep 30185
```

To force a rollout after an image tag change (same manifest, new `latest` digest):

```bash
sudo k3s kubectl rollout restart deployment/layer-gateway-api -n ai-dev
sudo k3s kubectl rollout status deployment/layer-gateway-api -n ai-dev
```

If the pod does not start:

```bash
sudo k3s kubectl describe pod -n ai-dev -l app=layer-gateway-api
sudo k3s kubectl logs -n ai-dev deploy/layer-gateway-api --tail=50
```

## 3) Smoke tests

From a host that can reach NodePort `30185` (default LAN control plane `192.168.86.179`). `jq` optional.

```bash
export GATEWAY_URL='http://192.168.86.179:30185'
```

Protected routes need `Authorization: Bearer <access_token>`. With Supabase:

```bash
curl -sS -X POST "${GATEWAY_URL}/v1/auth/login" \
  -H 'Content-Type: application/json' \
  -d '{"email":"you@example.com","password":"YOUR_PASSWORD"}' | jq .

export ACCESS_TOKEN='eyJ...'   # .access_token from the response
```

Username login uses `identifier` instead of `email` when [`sql/username_login.sql`](https://github.com/taixingbi/layer-gateway-api-v1/blob/main/sql/username_login.sql) is applied.

### 3.0 Probes and metrics (no auth)

```bash
curl -sS "${GATEWAY_URL}/health" | jq .
echo
curl -sS "${GATEWAY_URL}/ready" | jq .
echo
curl -sS "${GATEWAY_URL}/metrics" | head -n 40
echo
```

**Pass:** `/health` → `"status":"ok"`; `/ready` → **200** + `"orchestrator":"ok"` when orchestrator is up (**503** otherwise); `/metrics` contains `gateway_requests_total`.

### 3.1 `POST /v1/chat` (JSON, non-stream)

```bash
curl -sS -X POST "${GATEWAY_URL}/v1/chat" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -H "X-Session-Id: smoke-sess-001" \
  -H "X-Request-Id: smoke-req-001" \
  -H "X-Trace-Id: smoke-trace-001" \
  -d '{
    "conversation_id": "smoke-conv-001",
    "message": "What is Taixing US visa status?",
    "metadata": { "page": "/support", "user_agent": "curl" }
  }' | jq '{status, answer, request_id, trace_id, session_id, conversation_id, latency_ms, usage, citations, follow_up_questions}'
echo
```

**Pass:** `200`, `"status": "success"`, echoed ids, optional **`latency_ms`** and **`usage`**, no top-level **`error`**.

### 3.2 `POST /v1/chat` with `history`

```bash
curl -sS -X POST "${GATEWAY_URL}/v1/chat" \
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

### 3.3 `POST /v1/chat` (SSE)

```bash
curl -N -sS -X POST "${GATEWAY_URL}/v1/chat" \
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

**Pass:** `event: meta` → optional `event: rewrite` → `event: token` (…) → `event: done` with `latency_ms` / `usage` when upstream provides them.

### 3.4 Auth failure (expect 401)

```bash
curl -sS -o /dev/stderr -w "%{http_code}\n" -X POST "${GATEWAY_URL}/v1/chat" \
  -H "Content-Type: application/json" \
  -d '{"message":"should fail"}'
```

### 3.5 `POST /v1/feedback` (Supabase)

Use **`message_id`** and **`conversation_id`** from a prior **`POST /v1/chat`** response (assistant message UUID + conversation UUID).

**Thumbs up:**

```bash
curl -sS -X POST "${GATEWAY_URL}/v1/feedback" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "message_id": "<assistant_message_uuid>",
    "conversation_id": "<conversation_uuid>",
    "rating": "thumbs_up",
    "trace_id": "smoke-trace-001",
    "request_id": "smoke-req-001"
  }' | jq .
echo
```

**Thumbs down** (`feedback_reason` e.g. `not_factual`):

```bash
curl -sS -X POST "${GATEWAY_URL}/v1/feedback" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "message_id": "<assistant_message_uuid>",
    "conversation_id": "<conversation_uuid>",
    "rating": "thumbs_down",
    "feedback_reason": "not_factual",
    "comment": "Smoke test comment",
    "question": "What is Taixing US visa status?"
  }' | jq .
echo
```

**Pass:** `200` with `FeedbackResponse` when Supabase is configured; **`503`** if persistence is disabled.

### 3.6 Full stack (layer-web BFF)

[deploy-layer-web.md](deploy-layer-web.md) — browser → web `POST /api/v1/chat` → gateway `POST /v1/chat`; web translates SSE (`status`, `result_chunk`, `stream_end`, …). Sign in at `/login` first.

### 3.7 Checklist

| Step | Endpoint | Expect |
|------|----------|--------|
| 1 | `GET /health` | `200`, `"status":"ok"` |
| 2 | `GET /ready` | `200` if orchestrator healthy, else `503` |
| 3 | `GET /metrics` | `200`, `gateway_requests_total` |
| 4 | `POST /v1/auth/login` | `access_token` (Supabase) |
| 5 | `POST /v1/chat` (JSON) | `200`, success + `latency_ms` |
| 6 | `POST /v1/chat` SSE | `meta` → optional `rewrite` → `token` (…) → `done` |
| 7 | `POST /v1/feedback` | `200` when Supabase configured; else `503` |

## 4) Observability

Structured logs: `request_complete` JSON (`request_id`, `trace_id`, `session_id`, `latency_ms`, optional `ttfb_ms` on streams). Prometheus on `/metrics`:

- `gateway_requests_total{method,path,status}`
- `gateway_request_latency_ms_bucket`
- `gateway_ttfb_ms_bucket` (streaming)
- `gateway_inflight_requests`
- `gateway_rejected_requests_total{reason}` (e.g. `inflight_limit` → **503**)

After changing scrape rules:

```bash
sudo k3s kubectl apply -f manifests/observability/prometheus-grafana.yaml
sudo k3s kubectl rollout restart deployment/prometheus -n monitoring
```

Job `layer-gateway-api` scrapes Service `layer-gateway-api` in `ai-dev` (see [manifests/observability/prometheus-grafana.yaml](../manifests/observability/prometheus-grafana.yaml)).

## Troubleshooting

| Symptom | Check |
|---------|--------|
| `GET /ready` **503** | [deploy-orchestrator.md](deploy-orchestrator.md); `ORCHESTRATOR_READINESS_PROBE_ENABLED` |
| Empty / error answer | Pod logs; orchestrator `POST /v1/orchestrator/answer` from gateway pod |
| **401** on `/v1/chat` | `POST /v1/auth/login`; token expiry (`JWT_EXPIRY_SECONDS`) |
| **400** on `/v1/feedback` | `message_id` + `conversation_id` from prior chat; redeploy [layer-web-v1](deploy-layer-web.md) if UI sends legacy `trace_id`-only body |
| **503** on `/v1/feedback` | `SUPABASE_*` in secret §1 |
| **503** under load | `MAX_INFLIGHT_REQUESTS` (default `100`) |
| Stale image | Pull `latest` after [CI Push to Docker Hub](https://github.com/taixingbi/layer-gateway-api-v1/actions) |
| `CreateContainerConfigError` | `layer-gateway-api-secrets` missing §1 |
| Supabase feedback CHECK errors | upstream `sql/message_feedback_feedback_reason_constraint.sql` |

NodePort:

- dev: `30185`
