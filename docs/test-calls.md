# Test Calls

Gateway and RAG services use **NodePort** below; pods listen on **8000** (ClusterIP port `8000`). Examples use a GPU node IP; adjust if needed.

vLLM direct (`30080`):

```bash
curl http://192.168.86.173:30080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen/Qwen2.5-7B-Instruct","messages":[{"role":"user","content":"where is jersey city"}],"max_tokens":50}'
```

gateway dev (`30180`):

```bash
curl http://192.168.86.173:30180/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen/Qwen2.5-7B-Instruct","messages":[{"role":"user","content":"where is jersey city"}],"max_tokens":50}'
```

gateway prod (`30380`):

```bash
curl http://192.168.86.173:30380/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen/Qwen2.5-7B-Instruct","messages":[{"role":"user","content":"where is jersey city"}],"max_tokens":50}'
```

embedding gateway dev (`30181`) — requires `X-Request-Id`, `X-Trace-Id`, `X-Session-Id` ([layer-gateway-embed-v1](https://github.com/taixingbi/layer-gateway-embed-v1)):

```bash
curl -sS http://192.168.86.173:30181/health

curl -sS http://192.168.86.173:30181/v1/embeddings \
  -H "X-Request-Id: request_id_1" \
  -H "X-Trace-Id: trace_id_1" \
  -H "X-Session-Id: session_id_1" \
  -H "Content-Type: application/json" \
  -d '{"model":"BAAI/bge-m3","input":"hello world"}'
```
