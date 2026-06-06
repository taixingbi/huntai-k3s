# SSE streaming events (cross-service)

Shared token contract for all HuntAI streaming APIs:

```
event: answer_delta
data: {"text":"..."}
```

Parse token text from **`data.text`** on every hop. Citations, usage, and phase timings are on terminal **`done`** (or separate RAG-only events on direct `:30183`).

**Ports (dev):** [port.md](port.md) — RAG `30183`, orchestrator `30184`, gateway-api `30185`, MCP GitHub `30191`.

## Token contract by layer

| Layer | NodePort | Wire format | Token event | Payload |
|-------|----------|-------------|-------------|---------|
| **RAG direct** | `30183` | `event:` + `data:` | `answer_delta` | `{"text":"..."}` |
| **MCP GitHub direct** | `30191` | `event:` + `data:` | `answer_delta` | `{"text":"..."}` |
| **Orchestrator** | `30184` | `event:` + `data:` for tokens; other frames `data:` + `type` | `answer_delta` | `{"text":"..."}` |
| **Gateway API** | `30185` | `event:` + `data:` | `answer_delta` | `{"text":"..."}` |
| **Web BFF** | `30186` | `event:` + `data:` | `result_chunk` | `{delta}` (UI layer; upstream is gateway `answer_delta`) |

Legacy **`event: token`** (gateway) and **`event: delta`** (old MCP) may still be accepted by parsers during rollout; new clients should use **`answer_delta`** only.

## Client rules

### Direct RAG (`POST /v1/rag/query`, `:30183`)

Follow upstream [streaming.md](https://github.com/taixingbi/layer-rag-query-v1/blob/main/docs/streaming.md).

- **Tokens:** `event: answer_delta` → `data.text`.
- **Also on direct RAG only:** `meta`, `latency`, optional `retrieval_widen`, `answer_start` / `answer_end`, mid-stream `citations`, `follow_up_questions`, `usage`, `done`.

```bash
awk '/^event: answer_delta$/{p=1;next} /^event:/{p=0} p&&/^data: /{sub(/^data: /,""); print}' \
  /tmp/rag-stream.txt | jq -r '.text' | tr -d '\n'; echo
```

Deploy smoke: [deploy-rag-query.md §3.1](deploy-rag-query.md#31-post-v1ragquery-sse-stream-default).

### Direct MCP GitHub (`POST /v1/mcp`, `github_search`, `:30191`)

- **Tokens:** `event: answer_delta` → `data.text`.
- **Also expect:** `meta`, then `done` with full envelope.

```bash
awk '/^event: answer_delta$/{p=1;next} /^event:/{p=0} p&&/^data: /{sub(/^data: /,""); print}' \
  /tmp/mcp-stream.txt | jq -r '.text' | tr -d '\n'; echo
```

Deploy smoke: [deploy-mcp-github.md §3.3](deploy-mcp-github.md#33-mcp--sse-stream-default-stream--accept-textevent-stream).

### Orchestrator / Gateway (aggregated path)

**Do not** expect RAG-direct mid-stream events (`latency`, separate `citations` frames) on `:30184` or `:30185`.

- **Orchestrator (`30184`):** token frames are `event: answer_delta` with `data.text`; routing frames use `data: {"type":"rewrite"|"route"|"done", ...}`.
- **Gateway API (`30185`):** same token contract; citations / usage on `event: done`.

### RAG upstream failures (`ConnectError`)

If direct RAG SSE returns `event: error` with `ConnectError: All connection attempts failed`, check upstream gateways and Qdrant — see [deploy-rag-query.md §Troubleshooting](deploy-rag-query.md#troubleshooting).

## Related deploy docs

- [deploy-rag-query.md](deploy-rag-query.md)
- [deploy-mcp-github.md](deploy-mcp-github.md)
- [deploy-orchestrator.md](deploy-orchestrator.md)
- [deploy-gateway-api.md](deploy-gateway-api.md)
- [deploy-web.md](deploy-web.md)
