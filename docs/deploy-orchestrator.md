# Deploy Orchestrator (dev)

Service image: [ghcr.io/taixingbi/layer-orchestrator-v1](https://github.com/taixingbi/layer-orchestrator-v1/pkgs/container/layer-orchestrator-v1) — source: [layer-orchestrator-v1](https://github.com/taixingbi/layer-orchestrator-v1)

FastAPI orchestrator: intent router + optional RAG via **`POST /orchestrator/answer`** (aggregated JSON by default; SSE when `"stream": true`). NodePort **`30184`**; in-cluster: `http://layer-orchestrator:8000/orchestrator/answer`. Calls inference gateway (`POST …/v1/chat/completions`) and RAG (`POST …/v1/rag/query` on **layer-rag-query**).

Key endpoints:

- `GET /health` — liveness (`{"status":"ok"}`); build metadata on `GET /version`
- `GET /ready` — readiness (LLM gateway + RAG HTTP; **503** if either fails)
- `GET /metrics` — Prometheus (HTTP + pipeline histograms/counters)
- `POST v1/orchestrator/answer` — chat answer (JSON or SSE)
- `POST v1/orchestrator/eval/router` — router-only eval (no RAG)
- `POST v1/feedback` — thumbs up/down (optional LangSmith forward)

Upstream: [schema-request-response.md](https://github.com/taixingbi/layer-orchestrator-v1/blob/main/docs/schema-request-response.md), [conversation-id.md](https://github.com/taixingbi/layer-orchestrator-v1/blob/main/docs/conversation-id.md), [intent-router.md](https://github.com/taixingbi/layer-orchestrator-v1/blob/main/docs/intent-router.md), [smoke-test.md](https://github.com/taixingbi/layer-orchestrator-v1/blob/main/docs/smoke-test.md). Smoke curls below adapt `127.0.0.1:8000` → `192.168.86.179:30184`.

**Correlation:** `X-Request-Id`, `X-Session-Id`, `X-Trace-Id` on **headers** (not in the JSON body). If `X-Session-Id` is omitted, the orchestrator mints `ses_*` per request; multi-turn clients must send the **same** session id each turn. Optional **`conversation_id`** in the **`/orchestrator/answer`** and **`/orchestrator/eval/router`** JSON body; if omitted or blank, the server assigns `conv_*` and returns **`is_new_conversation`: true**. First SSE frame: `type: "correlation"` (see [correlation-ids.md](https://github.com/taixingbi/layer-orchestrator-v1/blob/main/docs/correlation-ids.md)).

**Access control:** optional `X-User-Id`, `X-User-Roles`, `X-User-Groups`, `X-User-Teams` are forwarded to RAG on `POST /v1/rag/query`.

**`latency_ms` (orchestrator vs tool):** On **`POST /orchestrator/answer`**, timings are **nested by phase**. Top-level **`latency_ms.total`** is end-to-end wall time; **`latency_ms.intent_router`** is the router LLM; when the router picks **`github_repo_search`**, MCP **`github_search`** timings (`github_readme`, `github_search`, `chat`, `follow_up_chat`, …) are merged under **`latency_ms.github`** together with **`latency_ms.github.orchestrator`** (orchestrator wall time for that tool call). Same pattern for RAG under **`latency_ms.rag`**. Do **not** expect flat `github_*` keys at the top level of an orchestrator response.

Direct **`POST /v1/mcp`** on [layer-mcp-github-v1](deploy-layer-mcp-github-v1.md) returns **tool-native** flat `latency_ms` (`github_readme`, `github_search`, `chat`, `total`, …) — that shape is correct for the MCP service only. Merging MCP SSE `done` JSON is not an orchestrator response; compare orchestrator with §4.5 below.

## Prerequisites

- Inference gateway in `ai-dev` — [deploy-gateway-inference.md](deploy-gateway-inference.md) (`layer-gateway-inference:8000` or NodePort `30180`)
- RAG query in `ai-dev` — [deploy-rag-query.md](deploy-rag-query.md) (`layer-rag-query:8000` or NodePort `30183`)
- GitHub MCP in `ai-dev` — [deploy-layer-mcp-github-v1.md](deploy-layer-mcp-github-v1.md) (`layer-mcp-github-v1:8000` or NodePort `30191`) when using **`github_repo_search`**
- Port map: [port.md](port.md) (`30184` dev)

## 1) Create secrets (Tavily web search)

The dev manifest uses `envFrom.secretRef.name=layer-orchestrator-secrets`. Create it in `ai-dev` before the Deployment can start (even if you only use RAG smoke tests — the key is loaded but unused until the router picks **`web_search`**).

```bash
mkdir -p ~/.secrets
chmod 700 ~/.secrets
printf '%s' 'tvly_YOUR_KEY' > ~/.secrets/tavily-api-key
chmod 600 ~/.secrets/tavily-api-key

sudo k3s kubectl create secret generic layer-orchestrator-secrets -n ai-dev \
  --from-file=TAVILY_API_KEY="$HOME/.secrets/tavily-api-key" \
  --dry-run=client -o yaml | sudo k3s kubectl apply -f -
```

Optional in the same Secret: `LANGCHAIN_API_KEY` or `LANGSMITH_API_KEY` for LangSmith feedback (§5).

## 2) Configure env

Edit [manifests/orchestrator/base/deployment.yaml](../manifests/orchestrator/base/deployment.yaml) for non-default settings (or push and let Argo CD sync). Full list: upstream [env.example](https://github.com/taixingbi/layer-orchestrator-v1/blob/main/env.example) and [`app/config.py`](https://github.com/taixingbi/layer-orchestrator-v1/blob/main/app/config.py).

| Variable | Dev manifest |
|----------|----------------|
| `LLM_GATEWAY_BASE_URL` | `http://layer-gateway-inference:8000` |
| `LLM_MODEL` | `Qwen/Qwen2.5-7B-Instruct` |
| `ROUTER_MODEL` | `router-qwen2.5-7b-sft-v1.00` (vLLM LoRA id; DPO: `router-qwen2.5-7b-dpo-v1.00`) |
| `ROUTER_PROMPT_VERSION` | `router-v2.01-compact` (fits vLLM `max-model-len` 2048 with history) |
| `RAG_HTTP_BASE_URL` | `http://layer-rag-query:8000` |
| `RAG_COLLECTION_BASE` | `taixing_knowledge` |
| `RAG_K` / `RAG_K_MAX` | `5` / `40` |
| `ROUTER_PROMPT_VERSION` | `router-v2.0.0` |
| `USE_MCP_TOOLS` | `true` |
| `MCP_GITHUB_BASE_URL` | `http://layer-mcp-github-v1:8000` |

Requires [layer-mcp-github-v1](deploy-layer-mcp-github-v1.md) when the router selects **`github_repo_search`** (`USE_MCP_TOOLS=true`).

Optional Tavily tuning (non-secret) in the manifest: `TAVILY_SEARCH_DEPTH` (default upstream: `advanced`), `TAVILY_MAX_RESULTS` (default `5`).

## 3) Deploy (Argo CD)

Orchestrator dev is managed by Argo CD Application `orchestrator-dev`. See [deploy-gitops-argocd.md](deploy-gitops-argocd.md) for install, bootstrap, and verify steps.

**Image tag:** dev overlay pins `ghcr.io/taixingbi/layer-orchestrator-v1:<12-char-sha>` in `manifests/orchestrator/overlays/dev/kustomization.yaml`. After each push to **layer-orchestrator-v1 `main`**, CI updates that tag in huntai-k3s; Argo CD syncs and rolls out. Re-pushing `:latest` alone does not rollout.

```bash
# optional: preload pinned tag from Git (see deploy-gitops-argocd.md §6)
TAG=$(grep newTag manifests/orchestrator/overlays/dev/kustomization.yaml | sed 's/.*"\(.*\)".*/\1/')
sudo k3s ctr images pull "ghcr.io/taixingbi/layer-orchestrator-v1:${TAG}"

sudo k3s kubectl get application orchestrator-dev -n argocd
sudo k3s kubectl get pods,svc -n ai-dev -l app=layer-orchestrator -o wide
sudo k3s kubectl get svc -A -o wide | grep 30184
```

If the pod does not start:

```bash
sudo k3s kubectl describe pod -n ai-dev -l app=layer-orchestrator
sudo k3s kubectl logs -n ai-dev deploy/layer-orchestrator --tail=50
```

## 4) Smoke tests

From a host that can reach NodePort `30184` (adjust IP if your server differs; default LAN control plane is `192.168.86.179`). `jq` is optional.

### 4.0 Ops — health, ready, metrics

```bash
curl -sS http://192.168.86.179:30184/health | jq .
echo
curl -sS http://192.168.86.179:30184/ready | jq .
echo
curl -sS http://192.168.86.179:30184/metrics | head -n 20
echo
```

**Pass:** `/health` → `"status":"ok"`; `/ready` → **200** when LLM gateway and RAG are reachable (**503** otherwise); `/metrics` → Prometheus text.

### 4.1 `POST /orchestrator/answer` (JSON, non-stream)

Uses the same internal pipeline as SSE; response is one aggregated JSON object. `route` is lowercase (e.g. `rag`, `direct_reply`).

```bash
curl -sS -X POST http://192.168.86.179:30184/v1/orchestrator/answer \
  -H "Content-Type: application/json" \
  -H "X-Session-Id: ses-123" \
  -H "X-Request-Id: req-123" \
  -H "X-Trace-Id: req-123" \
  -H "X-User-Id: taixing" \
  -H "X-User-Roles: hr" \
  -H "X-User-Groups: engineering" \
  H "X-User-Teams: rag-platform" \
  -d '{
    "question": "what is taixing visa status in us?",
    "conversation_id": "conv-smoke-1"
  }' | jq '{answer, route, conversation_id, is_new_conversation, latency_ms, usage}'
echo
```

**Pass:** non-empty `answer`; `conversation_id` present; `route` set. For **`route: "rag"`**, expect **`latency_ms.rag`** with nested service keys. For **`route: "tool"`** (github), expect **`latency_ms.github`** (see §4.5), not flat `github_readme` at the top level.

### 4.2 `POST /orchestrator/answer` with `history`

```bash
curl -sS -X POST http://192.168.86.179:30184/v1/orchestrator/answer \
  -H "Content-Type: application/json" \
  -H "X-Session-Id: ses-123" \
  -H "X-Request-Id: req-124" \
  -H "X-Trace-Id: req-124" \
  -d '{
    "question": "What does he location?",
    "conversation_id": "conv-smoke-1",
    "history": [
      {"role": "user", "content": "What is Taixing Bi US visa status?"},
      {"role": "assistant", "content": "Taixing has H4 EAD and does not need sponsorship."}
    ]
  }'
```

**Pass:** router produces `rewritten_question`; RAG runs only when `route` is `rag`.

### 4.3 `POST /orchestrator/answer` (SSE, `stream: true`)

Use `-N` for line-by-line SSE. Expect `request_id`, `rewrite`, `route`, `answer`, then `done` with `latency_ms` and `usage` (phase timings aggregated on `done`, not streamed line-by-line).

```bash
curl -N -sS -X POST http://192.168.86.179:30184/v1/orchestrator/answer \
  -H "Content-Type: application/json" \
  -H "X-Session-Id: ses-123" \
  -H "X-Request-Id: req-123" \
  -H "X-Trace-Id: req-123" \
  -H "X-User-Id: taixing" \
  -H "X-User-Roles: hr" \
  -H "X-User-Groups: engineering" \
  -H "X-User-Teams: rag-platform" \
  -d '{
    "question": "what is taixing visa status in us?",
    "stream": true,
    "conversation_id": "conv-smoke-1"
  }'
```

**Pass:** SSE JSON lines with `"type":"answer"` and terminal `"type":"done"`.

### 4.4 `POST /orchestrator/eval/router` (optional)

Router rewrite/route only — no RAG call.

```bash
curl -sS -X POST http://192.168.86.179:30184/v1/orchestrator/eval/router \
  -H "Content-Type: application/json" \
  -H "X-Session-Id: ses-123" \
  -H "X-Request-Id: req-router-1" \
  -H "X-Trace-Id: req-router-1" \
  -d '{
    "question": "What are the renewal requirements for H4 EAD?",
    "expected_route": "direct_reply",
    "conversation_id": "conv-router-eval-1",
    "router_temperature": 0,
    "history": [
      {"role": "user", "content": "What is Taixing Bi US visa status?"},
      {"role": "assistant", "content": "H4 EAD. No visa sponsorship required. [1]"}
    ]
  }' | jq '{conversation_id, decision: .decision.route, evaluation: .evaluation.all_checks_pass}'
```

**Pass:** `decision.route` and `evaluation.all_checks_pass` present.

### 4.5 `POST /orchestrator/answer` — GitHub MCP route (optional)

When the router selects **`github_repo_search`**, orchestrator calls **`github_search`** on **layer-mcp-github-v1** (`MCP_GITHUB_BASE_URL`). Validate nested latency (not flat tool keys at top level):

```bash
curl -sS -X POST http://192.168.86.179:30184/v1/orchestrator/answer \
  -H "Content-Type: application/json" \
  -H "X-Session-Id: ses-123" \
  -H "X-Request-Id: req-github-1" \
  -H "X-Trace-Id: req-github-1" \
  -d '{
    "question": "In layer-orchestrator-v1, what does POST /orchestrator/answer do?",
    "conversation_id": "conv-github-1"
  }' | jq '{
    route,
    route_detail,
    latency_ms: {
      total: .latency_ms.total,
      intent_router: .latency_ms.intent_router,
      github: .latency_ms.github
    }
  }'
```

**Pass:** `route` is `tool` and `route_detail.name` is `github_repo_search`; **`latency_ms.total`** present; **`latency_ms.github`** contains merged tool timings (`github_readme`, `github_search`, `chat`, …) plus **`orchestrator`** wall time. If you only see flat `github_*` at **`latency_ms`** top level, pull a current orchestrator image (see [schema-request-response.md § latency_ms](https://github.com/taixingbi/layer-orchestrator-v1/blob/main/docs/schema-request-response.md)).

### 4.6 Checklist

| Step | Endpoint | Expect |
|------|----------|--------|
| 1 | `GET /health` | `"status":"ok"` |
| 2 | `GET /ready` | **200** (LLM + RAG up) |
| 3 | `GET /metrics` | Prometheus text |
| 4 | `/orchestrator/answer` JSON | `answer`, `route`, `conversation_id` |
| 5 | `/orchestrator/answer` + `history` | `rewritten_question` when routed |
| 6 | `/orchestrator/answer` SSE | `answer` + `done` events |
| 7 | `/orchestrator/eval/router` (optional) | `decision`, `evaluation` |
| 8 | GitHub MCP route (optional) | `latency_ms.github` nested, not flat tool keys |

## 5) Feedback

Logs locally always; forwards to LangSmith only when `LANGCHAIN_API_KEY` or `LANGSMITH_API_KEY` is set. Run id priority: **`agent_graph_run_id`** → **`trace_id`** → **`request_id`**.

**Thumbs up** (same `trace_id` / `request_id` as §4.1):

```bash
curl -sS -X POST http://192.168.86.179:30184/feedback \
  -H "Content-Type: application/json" \
  -d '{
    "trace_id": "req-123",
    "request_id": "req-123",
    "rating": "thumbs_up"
  }' | jq .
```

**Thumbs down** with optional `feedback_type` and `comment`:

```bash
curl -sS -X POST http://192.168.86.179:30184/feedback \
  -H "Content-Type: application/json" \
  -d '{
    "trace_id": "req-123",
    "rating": "thumbs_down",
    "feedback_type": "not_factual",
    "comment": "Answer did not match the cited policy",
    "question": "what is taixing visa status in us?"
  }' | jq .
```

`feedback_type` (optional): `not_relevant`, `biased`, `not_factual`, `incomplete_instructions`, `unsafe`, `style_tone`, `other`.

## Troubleshooting

| Symptom | Check |
|---------|--------|
| `GET /ready` **503** | [deploy-gateway-inference.md](deploy-gateway-inference.md) (`30180`); [deploy-rag-query.md](deploy-rag-query.md) (`30183`) |
| Empty / error answer | Pod logs; RAG `POST /v1/rag/query` from orchestrator pod |
| **413** on `/orchestrator/answer` | `MAX_REQUEST_BODY_MB` (default `1`) |
| **400** history / context | `MAX_HISTORY_MESSAGES` (`50`), `MAX_CONTEXT_CHARS` (`120000`) |
| **504** timeout | `REQUEST_TIMEOUT_MS` (`30000`); downstream latency |
| `CreateContainerConfigError` | Secret `layer-orchestrator-secrets` missing; §1 |
| Wrong router behavior | `ROUTER_PROMPT_VERSION` in manifest; §4.4 eval |
| Flat `github_*` in orchestrator `latency_ms` | Expected nested under `latency_ms.github`; upgrade orchestrator image |
| `web_search` / Tavily errors | Valid `TAVILY_API_KEY` in `layer-orchestrator-secrets` §1 |

NodePort:

- dev: `30184`
6+-