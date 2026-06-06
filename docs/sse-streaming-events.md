# SSE streaming events (cross-service)

How token and metadata events differ by hop. Use this when writing curl smoke tests, SSE parsers, or UI clients.

**Ports (dev):** [port.md](port.md) — RAG `30183`, orchestrator `30184`, gateway-api `30185`, MCP GitHub `30191`.

## Token event names by layer

| Layer | NodePort | Wire format | Token event | Token payload |
|-------|----------|-------------|-------------|---------------|
| **RAG direct** | `30183` | `event:` + `data:` | `answer_delta` | `{"text":"..."}` |
| **MCP GitHub direct** | `30191` | `event:` + `data:` | `delta` | `{"answer":{"text":"..."}}` |
| **Orchestrator** | `30184` | `data:` only (`type` in JSON) | `answer_delta` | `{"type":"answer_delta","text":"..."}` |
| **Gateway API** | `30185` | `event:` + `data:` | `token` | `{"text":"..."}` |
| **Web BFF** | `30186` | `event:` + `data:` | `result_chunk` | (maps from gateway `token`) |

Orchestrator normalizes MCP GitHub `delta` → `answer_delta` before emitting to clients. Gateway API maps orchestrator `answer_delta` → `token`.

## Client rules

### Direct RAG (`POST /v1/rag/query`, `:30183`)

Follow upstream [streaming.md](https://github.com/taixingbi/layer-rag-query-v1/blob/main/docs/streaming.md).

- **Tokens:** `event: answer_delta` → parse `data.text`.
- **Also expect:** `meta`, `latency`, optional `retrieval_widen`, `answer_start` / `answer_end`, `citations`, `follow_up_questions`, `usage`, `done` (and `error` → `done` on failure).
- Citations and usage are **separate events**, not only on `done`.

```bash
# extract streamed answer text
awk '/^event: answer_delta$/{p=1;next} /^event:/{p=0} p&&/^data: /{sub(/^data: /,""); print}' \
  /tmp/rag-stream.txt | jq -r '.text' | tr -d '\n'; echo
```

Deploy smoke: [deploy-rag-query.md §3.1](deploy-rag-query.md#31-post-v1ragquery-sse-stream-default).

### Direct MCP GitHub (`POST /v1/mcp`, `github_search`, `:30191`)

- **Tokens:** `event: delta` → parse `data.answer.text` (not top-level `text`).
- **Also expect:** `meta` (body is `{"meta":{...}}`), then `done` with full envelope (`answer`, `citations`, `follow_up_questions`, `usage`, `latency_ms`).
- **No** RAG-style `latency`, `citations`, or `usage` as separate mid-stream events.
- Requires `Accept: text/event-stream` for SSE (buffered JSON when `stream: false`).

```bash
# extract streamed answer text
awk '/^event: delta$/{p=1;next} /^event:/{p=0} p&&/^data: /{sub(/^data: /,""); print}' \
  /tmp/mcp-stream.txt | jq -r '.answer.text' | tr -d '\n'; echo
```

Deploy smoke: [deploy-mcp-github.md §3.3](deploy-mcp-github.md#33-mcp--sse-stream-default-stream--accept-textevent-stream).

### Orchestrator / Gateway (aggregated client path)

**Do not** assume RAG-direct mid-stream events (`latency`, `citations`, `follow_up_questions`, `usage` as separate SSE frames).

- **Orchestrator (`30184`):** read `data:` JSON; tokens are `type: "answer_delta"` with `text`. Terminal `type: "done"` carries citations, usage, `latency_ms`.
- **Gateway API (`30185`):** tokens are `event: token` with `data.text`; citations / follow-ups / usage on `event: done` (gateway may supplement `done` if the stream omitted them).

Orchestrator stream types: `correlation`, `rewrite`, `route`, `answer_delta`, `done`, `error` — see [schema-request-response.md](https://github.com/taixingbi/layer-orchestrator-v1/blob/main/docs/schema/schema-request-response.md).

Gateway stream events: `meta`, `rewrite`, `route`, `token`, `done`, `error` — see [gateway-api schema.md](https://github.com/taixingbi/layer-gateway-api-v1/blob/main/docs/schema.md).

## RAG upstream failures (`ConnectError`)

If direct RAG SSE returns `event: error` with `ConnectError: All connection attempts failed`, an upstream dependency is unreachable from the RAG pod (not an SSE naming issue).

Check in order:

1. `curl -sS :30183/ready` — Qdrant reachable?
2. Gateway pods ready: embedding (`30181`), reranker (`30182`), inference (`30180`) — each `/ready`.
3. `kubectl -n ai-dev logs deploy/layer-rag-query --tail=50` for the failing URL.

See [deploy-rag-query.md §1–2](deploy-rag-query.md) and gateway deploy docs.

## Related deploy docs

- [deploy-rag-query.md](deploy-rag-query.md)
- [deploy-mcp-github.md](deploy-mcp-github.md)
- [deploy-orchestrator.md](deploy-orchestrator.md)
- [deploy-gateway-api.md](deploy-gateway-api.md)
- [deploy-web.md](deploy-web.md) — BFF renames gateway events for the chat UI
