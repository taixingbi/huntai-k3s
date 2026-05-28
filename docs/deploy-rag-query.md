# Deploy RAG Query (dev)

Service image: [taixingbi/layer-rag-query-v1](https://hub.docker.com/r/taixingbi/layer-rag-query-v1) — source: [layer-rag-query-v1](https://github.com/taixingbi/layer-rag-query-v1)

Hybrid retrieval (dense + BM25 + RRF) with optional rerank and chat completion. **`POST /v1/rag/query`** on port **8000** (JSON or SSE). MCP over HTTP: **`POST /v1/mcp`** (use `/v1/mcp` not `/v1/mcp/`). NodePort **`30183`**; in-cluster: `http://layer-rag-query:8000/v1/rag/query`.

Key endpoints:

- `GET /health` — liveness (`status`, `app_name`, `app_version`)
- `GET /version` — build identity
- `GET /ready` — readiness (Qdrant `get_collections`; **503** if unreachable)
- `GET /metrics` — Prometheus (`rag_query_*`, `http_*`)
- `POST /v1/rag/query` — RAG answer (JSON or SSE)
- `POST /v1/mcp` — FastMCP `tools/call` (`rag_query` with `stream: true|false`; aliases `rag_query_stream`, `answer_from_inference`)

Upstream: [schema.md](https://github.com/taixingbi/layer-rag-query-v1/blob/main/docs/schema.md), [streaming.md](https://github.com/taixingbi/layer-rag-query-v1/blob/main/docs/streaming.md), [access-control.md](https://github.com/taixingbi/layer-rag-query-v1/blob/main/docs/access-control.md), [smoke-test.md](https://github.com/taixingbi/layer-rag-query-v1/blob/main/docs/smoke-test.md). Smoke curls below adapt `127.0.0.1:8000` → `192.168.86.179:30183`.

**Correlation:** `X-Request-Id`, `X-Session-Id`, `X-Trace-Id` are **header-only** (blank/missing request or session → server UUID). Putting `request_id`, `session_id`, or `trace_id` in the JSON body returns **400**. `conversation_id` stays in the JSON body (optional; server generates `conv_*` when omitted).

**Collection naming:** manifest sets `ENV=dev`; `collection_base` `taixing_knowledge` resolves to Qdrant collection `taixing_knowledge_dev`.

Environment variables follow upstream [`app/core/config.py`](https://github.com/taixingbi/layer-rag-query-v1/blob/main/app/core/config.py) and [`.env.example`](https://github.com/taixingbi/layer-rag-query-v1/blob/main/.env.example). The dev manifest uses LAN `192.168.86.179` for Qdrant (`6333`), embedding gateway (`30181`), reranker gateway (`30182`), and inference **gateway** (`30180`). In-cluster callers may use Service DNS on port `8000` (e.g. `http://layer-gateway-inference:8000`).

## Prerequisites

- Qdrant reachable at `QDRANT_URL` (manifest default: `http://192.168.86.179:6333` — adjust if yours differs).
- Embedding gateway NodePort `30181`, reranker gateway `30182`, inference gateway `30180` (manifest defaults). Override `INFERENCE_URL` for direct vLLM (`30080`) or in-cluster DNS as needed.
- Port map: [port.md](port.md) (`30183` dev).

## 1) Configure env (no `secretRef` by default)

Edit [manifests/rag/base/deployment.yaml](../manifests/rag/base/deployment.yaml) for non-default Qdrant host, `QDRANT_API_KEY`, model names, or `ENV`. For Grafana Cloud Loki from the app, add `GRAFANA_CLOUD_*` env vars per upstream `.env.example` (not set in this manifest by default).

| Variable | Dev manifest |
|----------|----------------|
| `ENV` | `dev` |
| `EMBEDDING_URL` | `http://192.168.86.179:30181` |
| `RERANK_URL` | `http://192.168.86.179:30182` |
| `INFERENCE_URL` | `http://192.168.86.179:30180` |
| `INFERENCE_MODEL` | `Qwen/Qwen2.5-7B-Instruct` |

## 2) Deploy via Argo CD (GitOps)

```bash
# optional: preload image on the node
sudo k3s ctr images pull docker.io/taixingbi/layer-rag-query-v1:latest

# one-time: register Argo CD app
sudo k3s kubectl apply -f argocd/applications/rag-query-dev.yaml
sudo k3s kubectl get application rag-query-dev -n argocd

sudo k3s kubectl get pods,svc -n ai-dev -l app=layer-rag-query -o wide
sudo k3s kubectl get svc -A -o wide | grep 30183
```

If the pod does not start:

```bash
sudo k3s kubectl describe pod -n ai-dev -l app=layer-rag-query
sudo k3s kubectl logs -n ai-dev deploy/layer-rag-query --tail=50
```

## 3) Smoke tests

From a host that can reach NodePort `30183` (adjust IP if your server differs; default LAN control plane is `192.168.86.179`). `jq` is optional.

### 3.0 Ops — health, version, ready, metrics

```bash
curl -sS http://192.168.86.179:30183/health | jq .
echo
curl -sS http://192.168.86.179:30183/version | jq .
echo
curl -sS http://192.168.86.179:30183/ready | jq .
echo
curl -sS http://192.168.86.179:30183/metrics | head -n 20
echo
```

**Pass:** `/health` → `"status":"ok"`; `/version` → `app_name` + `app_version`; `/ready` → `"status":"ready"` when Qdrant is reachable; `/metrics` → Prometheus text including `rag_query_` or `http_requests_total`.

### 3.1 `POST /v1/rag/query` (SSE stream, default)

Access-control headers are optional; roles default to `anyuser` when omitted. See [access-control.md](https://github.com/taixingbi/layer-rag-query-v1/blob/main/docs/access-control.md).

```bash
curl -N -sS -X POST http://192.168.86.179:30183/v1/rag/query \
  -H "Content-Type: application/json" \
  -H "Accept: text/event-stream" \
  -H "X-Request-Id: req-abc123" \
  -H "X-Session-Id: ses-xyz789" \
  -H "X-Trace-Id: trc-001" \
  -H "X-User-Id: taixing" \
  -H "X-User-Roles: hr" \
  -H "X-User-Groups: engineering" \
  -H "X-User-Teams: rag-platform" \
  -d '{
    "question": "What is the current US visa status of Taixing?",
    "conversation_id": "conv_rag_1",
    "collection_base": "taixing_knowledge",
    "k": 5,
    "k_max": 50
  }'
echo
```

**Pass:** SSE lines with `event: meta`, `event: answer_delta`, `event: done`.

### 3.2 `POST /v1/rag/query` (JSON, non-stream)

Default is stream response. Set `"stream": false` for non-stream JSON.

```bash
curl -sS -X POST http://192.168.86.179:30183/v1/rag/query \
  -H "Content-Type: application/json" \
  -H "X-Request-Id: req-abc123" \
  -H "X-Session-Id: ses-xyz789" \
  -H "X-Trace-Id: trc-001" \
  -H "X-User-Roles: hr" \
  -H "X-User-Groups: engineering" \
  -H "X-User-Teams: rag-platform" \
  -d '{
    "question": "what is taixing visa status",
    "conversation_id": "conv_rag_1",
    "collection_base": "taixing_knowledge",
    "stream": false,
    "k": 5,
    "k_max": 50
  }' | jq '{answer, citations: (.citations|length), follow_up_questions, request_id, session_id, trace_id, conversation_id}'
```

**Pass:** non-empty `answer`, `citations`, correlation fields echoed; `follow_up_questions` present (may be `[]`).

### 3.3 MCP — list tools

```bash
curl -sS -X POST \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' \
  http://192.168.86.179:30183/v1/mcp | jq -r '.result.tools[].name' | sort
```

**Pass:** includes `rag_query`, `retrieve_chunks`, `embed_text`, and aliases `rag_query_stream`, `answer_from_inference`. Use `/v1/mcp` not `/v1/mcp/`.

On HTTP MCP, every `POST /v1/mcp` call needs **`Accept: application/json, text/event-stream`** (not `application/json` alone). Set `X-Request-Id` / `X-Session-Id` / `X-Trace-Id` (and optional `X-User-*`) on the **curl** request only — do **not** put `request_id`, `session_id`, or `trace_id` in `rag_query` `arguments` (use headers, same as §3.1). Prefer **`POST /v1/rag/query`** for plain JSON; use MCP when testing tools. Responses may be SSE `data:` lines — parse with upstream [smoke-test.md § MCP](https://github.com/taixingbi/layer-rag-query-v1/blob/main/docs/smoke-test.md#mcp-over-http-v1mcp) (`result.content[0].text` or `result.structuredContent`).

### 3.4 MCP — `rag_query` (`stream: false`, JSON)

Same response shape as §3.1 `POST /v1/rag/query`.

```bash
curl -sS --max-time 120 -X POST http://192.168.86.179:30183/v1/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "X-Request-Id: req-mcp-1" \
  -H "X-Session-Id: ses-mcp-1" \
  -H "X-Trace-Id: trc-mcp-1" \
  -H "X-User-Roles: hr" \
  -H "X-User-Groups: engineering" \
  -H "X-User-Teams: rag-platform" \
  -d '{
    "jsonrpc":"2.0",
    "id":"mcp-rag-1",
    "method":"tools/call",
    "params":{
      "name":"rag_query",
      "arguments":{
        "question":"What is the current US visa status of Taixing?",
        "collection_base":"taixing_knowledge",
        "conversation_id":"conv_mcp_1",
        "stream":false,
        "k":5,
        "k_max":50
      }
    }
  }' | tee /tmp/mcp-rag.json | jq '.result.structuredContent // empty | {answer, citations: (.citations|length), follow_up_questions, request_id, conversation_id}'
```

**Pass:** non-empty `answer`, `citations`, correlation fields in `structuredContent`.

### 3.5 MCP — `rag_query` (`stream: true`, events JSON)

Returns `{"events": [...]}` with SSE-shaped event objects (`type`: `meta`, `answer_delta`, `done`, …). Same as `rag_query_stream` (alias).

```bash
curl -sS --max-time 120 -X POST http://192.168.86.179:30183/v1/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "X-Request-Id: req-mcp-stream-1" \
  -H "X-Session-Id: ses-mcp-stream-1" \
  -H "X-Trace-Id: trc-mcp-stream-1" \
  -H "X-User-Id: taixing" \
  -H "X-User-Roles: hr" \
  -d '{
    "jsonrpc":"2.0",
    "id":"mcp-stream-1",
    "method":"tools/call",
    "params":{
      "name":"rag_query",
      "arguments":{
        "question":"what is taixing visa status",
        "collection_base":"taixing_knowledge",
        "conversation_id":"conv_mcp_stream_1",
        "stream":true,
        "k":5,
        "k_max":50
      }
    }
  }' | tee /tmp/mcp-rag-stream.txt

# If the response is a single JSON-RPC object:
jq '.result.structuredContent | {event_count: (.events|length), event_types: ([.events[].type] | unique)}' /tmp/mcp-rag-stream.txt

# If FastMCP returns SSE data: lines:
sed -n 's/^data: //p' /tmp/mcp-rag-stream.txt | tail -1 | jq -r '.result.content[0].text // empty' | jq '{event_count: (.events|length), event_types: ([.events[].type] | unique)}'
```

**Pass:** `event_count` > 0; `event_types` includes `meta` and `done`.

### 3.6 Checklist

| Step | Endpoint | Expect |
|------|----------|--------|
| 1 | `GET /health` | `"status":"ok"` |
| 2 | `GET /version` | `app_name`, `app_version` |
| 3 | `GET /ready` | `"status":"ready"` (Qdrant up) |
| 4 | `GET /metrics` | Prometheus text |
| 5 | `POST /v1/rag/query` JSON | `answer`, citations, correlation ids |
| 6 | `POST /v1/rag/query` SSE | `meta` → … → `done` |
| 7 | `tools/list` on `/v1/mcp` | RAG MCP tools listed |
| 8 | MCP `rag_query` | `structuredContent` with answer + citations |
| 9 | MCP `rag_query` `stream: true` | `events` with `meta`, `done` |

### 3.7 Upstream dependencies (optional)

From a host on the LAN, verify backends the manifest points at (adjust IP if needed):

```bash
# Qdrant
curl -sS http://192.168.86.179:6333/collections | jq -r '.result.collections[].name' | grep taixing_knowledge_dev

# Embedding gateway (30181)
curl -sS -X POST http://192.168.86.179:30181/v1/embeddings \
  -H "X-Request-Id: req-dep-1" -H "X-Session-Id: ses-dep-1" \
  -H "Content-Type: application/json" \
  -d '{"model":"BAAI/bge-m3","input":"hello"}' | jq '{data_len: (.data|length)}'

# Reranker gateway (30182)
curl -sS -X POST http://192.168.86.179:30182/v1/rerank \
  -H "X-Request-Id: req-dep-1" -H "X-Session-Id: ses-dep-1" \
  -H "Content-Type: application/json" \
  -d '{"model":"BAAI/bge-reranker-v2-m3","query":"visa","documents":["H4 EAD"],"top_n":1}' \
  | jq '{results: (.results|length)}'

# Inference gateway (30180)
curl -sS -X POST http://192.168.86.179:30180/v1/chat/completions \
  -H "X-Request-Id: req-dep-1" -H "X-Session-Id: ses-dep-1" \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen/Qwen2.5-7B-Instruct","messages":[{"role":"user","content":"ping"}],"max_tokens":8}' \
  | jq '{has_choices: (.choices|length>0)}'
```

**Pass:** `taixing_knowledge_dev` exists; embedding returns `data`; chat returns choices.

## 4) Observability

After changing scrape rules, reload Prometheus:

```bash
sudo k3s kubectl apply -f manifests/observability/prometheus-grafana.yaml
sudo k3s kubectl rollout restart deployment/prometheus -n monitoring
```

Prometheus discovers Service `layer-rag-query` in `ai-dev` with label `workload=rag-query` (see [manifests/observability/prometheus-grafana.yaml](../manifests/observability/prometheus-grafana.yaml)). Scrapes `GET /metrics` on port `8000`.

## 5) Cursor / MCP clients

The container runs **HTTP** (`python -m app.main` / FastMCP HTTP on port **8000**), not stdio-only.

- RAG API: `http://192.168.86.179:30183/v1/rag/query`
- MCP: `http://192.168.86.179:30183/v1/mcp`
- Port-forward: `sudo k3s kubectl port-forward -n ai-dev svc/layer-rag-query 8000:8000` → `http://127.0.0.1:8000/v1/mcp`

Enable MCP server **layer-rag-query** per upstream [`.cursor/mcp.json`](https://github.com/taixingbi/layer-rag-query-v1/blob/main/.cursor/mcp.json) (stdio uses venv `python` + `app/main.py`; HTTP uses the URLs above).

## Troubleshooting

| Symptom | Check |
|---------|--------|
| `GET /ready` **503** | `QDRANT_URL`; Qdrant reachable from pod |
| **400** on `/v1/rag/query` | No `request_id` / `session_id` / `trace_id` / `user_*` in JSON body |
| Empty answer / **502** | `INFERENCE_URL` (`30180`), `EMBEDDING_URL` (`30181`), `RERANK_URL` (`30182`) |
| Wrong collection | `ENV=dev` + `collection_base` → `taixing_knowledge_dev` |
| Empty curl body (MCP) | `/v1/mcp` not `/v1/mcp/` |
| MCP `rag_query` with ids in `arguments` | Use `X-Request-Id` / `X-Session-Id` / `X-Trace-Id` headers instead |
| MCP `Not Acceptable` / empty body | `Accept: application/json, text/event-stream` on every `/v1/mcp` call |
| Empty MCP `structuredContent` | Parse SSE `data:` lines per §3.3; check `.result.isError` with `jq .` |
| Prometheus target down | Pull latest image; confirm `GET /metrics` §3.0 |

NodePort:

- dev: `30183`
