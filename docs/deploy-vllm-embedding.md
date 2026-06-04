# Deploy vLLM embedding (BAAI/bge-m3)

Dense embedding inference runs **inside the per-GPU vLLM bundle** on port **8001**. It is **not** a separate Deployment — one `vllm serve` process per bundle Pod, alongside chat (`:8000`) and rerank (`:8002`). Bundle overview: [deploy-vllm-inference.md](deploy-vllm-inference.md). Client-facing routing: [deploy-gateway-embedding.md](deploy-gateway-embedding.md) (NodePort **30181**).

GitOps: Argo CD Application **`vllm-inference`** (`manifests/ai`). Startup script: ConfigMap **`vllm-bundle-start`** → [`manifests/ai/vllm-bundle-start-configmap.yaml`](../manifests/ai/vllm-bundle-start-configmap.yaml).

## Layout

| Item | Value |
|------|--------|
| Model | `BAAI/bge-m3` |
| Port (in Pod) | **8001** |
| API | `POST /v1/embeddings` (OpenAI-compatible) |
| Vector size | **1024** (must match RAG `VECTOR_SIZE` / Qdrant collection) |
| GPU util (default) | `0.08` |
| `max-model-len` | `8192` |
| Start order | **First** (before rerank and chat) |

Per-node ClusterIP Services (namespace **`ai`**, gateway backends):

| Service | Backend |
|---------|---------|
| `vllm-embed-gpu-node-1` | `gpu-node-1` bundle Pod |
| `vllm-embed-gpu-node-2` | `gpu-node-2` bundle Pod |

LAN smoke tests: NodePort **`30081`** on **`embedding-bge-m3`** (same pattern as chat **`30080`**). Production clients use the **embedding gateway** on **30181**.

Embedding gateway **`EMBED_BACKENDS`** (in `manifests/gateway-embedding/base/deployment.yaml`):

```text
embed-node-1=http://vllm-embed-gpu-node-1.ai.svc.cluster.local:8001
embed-node-2=http://vllm-embed-gpu-node-2.ai.svc.cluster.local:8001
```

## Required `vllm serve` flags

On **`vllm/vllm-openai:latest`**, dense RAG embeddings need **pooling mode** with an explicit **embed** task. Do **not** use `BgeM3EmbeddingModel` hf-overrides unless you also change clients to call **`/pooling`** (sparse/colbert); that override breaks **`/v1/embeddings`** with **501**.

Current bundle command (from ConfigMap):

```bash
vllm serve BAAI/bge-m3 \
  --host 0.0.0.0 --port 8001 \
  --runner pooling \
  --pooler-config '{"task":"embed"}' \
  --enforce-eager \
  --gpu-memory-utilization 0.08 \
  --max-model-len 8192
```

Edit the ConfigMap and push to `main`; bump **`huntai.ai/vllm-bundle-start-revision`** on the bundle Pod template (or `rollout restart`) so Pods pick up the script — ConfigMap updates alone do **not** reload running Pods. See [deploy-vllm-inference.md § ConfigMap changes](deploy-vllm-inference.md#configmap-changes-require-a-pod-restart).

## Rollout and readiness

```bash
sudo k3s kubectl get application vllm-inference -n argocd
sudo k3s kubectl get pods -n ai -l app=vllm-bundle -o wide
sudo k3s kubectl rollout status deploy/vllm-bundle-gpu-node-1 -n ai --timeout=45m
sudo k3s kubectl rollout status deploy/vllm-bundle-gpu-node-2 -n ai --timeout=45m
```

Bundle **`healthcheck.py`** probes all three `/health` endpoints and **`POST /v1/embeddings`** on `:8001`. A Pod stays **NotReady** until embed returns a non-empty `data` array (not **501**).

```bash
sudo k3s kubectl exec -n ai deploy/vllm-bundle-gpu-node-1 -- python3 /scripts/healthcheck.py
```

**Pass:** lines `ok embed http://127.0.0.1:8001/health` and `ok embed /v1/embeddings`.

Confirm live script:

```bash
sudo k3s kubectl exec -n ai deploy/vllm-bundle-gpu-node-1 -- \
  grep -A8 'starting embed' /scripts/start-vllm-bundle.sh
```

## Smoke tests

Run after both bundle Pods are **`1/1 Ready`**. GPU node-1 embed NodePort: **`192.168.86.173:30081`**. `jq` is optional.

### 2) Embed — NodePort `30081`

```bash
curl -sS http://192.168.86.173:30081/health | jq .
echo
curl -sS http://192.168.86.173:30081/v1/models | jq '.data[].id'
echo
curl -sS http://192.168.86.173:30081/v1/embeddings \
  -H "Content-Type: application/json" \
  -d '{"model":"BAAI/bge-m3","input":"hello world"}' \
  | jq
echo
```

```bash
curl -sS http://192.168.86.176:30081/health | jq .
echo
curl -sS http://192.168.86.176:30081/v1/models | jq '.data[].id'
echo
curl -sS http://192.168.86.176:30081/v1/embeddings \
  -H "Content-Type: application/json" \
  -d '{"model":"BAAI/bge-m3","input":"hello world"}' \
  | jq
echo
```

**Pass:** `/health` ok; `/v1/models` lists `BAAI/bge-m3`; **`data_len: 1`**, no `error`. Via gateway: [deploy-gateway-embedding.md](deploy-gateway-embedding.md) (`30181`).

### 3) Via embedding gateway (production path)

Requires correlation headers. See [deploy-gateway-embedding.md §5](deploy-gateway-embedding.md#5-example-post-v1embeddings).

```bash
curl -sS http://192.168.86.179:30181/v1/embeddings \
  -H "X-Request-Id: req-1" \
  -H "X-Trace-Id: req-1" \
  -H "X-Session-Id: ses-1" \
  -H "Content-Type: application/json" \
  -d '{"model":"BAAI/bge-m3","input":"hello world"}' \
  | jq
```

**Pass:** `data_len: 1`, no `error`.

### Port-forward (optional)

```bash
sudo k3s kubectl port-forward -n ai svc/vllm-embed-gpu-node-1 8001:8001
curl -sS -X POST http://127.0.0.1:8001/v1/embeddings \
  -H "Content-Type: application/json" \
  -d '{"model":"BAAI/bge-m3","input":"hello"}' | jq '{data_len: (.data|length)}'
```

## Troubleshooting

| Symptom | Likely cause | Action |
|---------|----------------|--------|
| **501** `The model does not support Embeddings API` | Wrong pooling task or `BgeM3EmbeddingModel` override | Use `--runner pooling` + `--pooler-config '{"task":"embed"}'`; remove hf-overrides; restart bundle |
| Gateway `/ready` **2/2** but **501** on `POST /v1/embeddings` | Gateway only probes backend **`/health`** | Fix vLLM embed (above); rely on bundle `healthcheck.py` |
| Pod **0/1 Ready**, rollout stuck | Embed API probe failing | `kubectl exec … python3 /scripts/healthcheck.py`; fix script; `rollout restart` |
| Script correct, still **501** | `vllm/vllm-openai:latest` behavior drift | Pin image tag in `vllm-bundle.yaml`; validate flags on that tag |
| RAG **`not_ready`** / embed errors | Upstream embed broken | Fix bundle embed first, then [deploy-rag-query.md](deploy-rag-query.md) |

Logs:

```bash
sudo k3s kubectl logs -n ai deploy/vllm-bundle-gpu-node-1 -c vllm-bundle --tail=100
sudo k3s kubectl logs -n ai -l vllm-node=gpu-node-1 -c prefetch-hf-cache
```

## Observability

Prometheus discovers **`vllm-embed-gpu-node-*`** Services with label **`workload=embedding`** (`manifests/observability/prometheus-grafana.yaml`). Grafana dashboard: `grafana-import/dashboard/embedding.json`.

## Related

- Bundle (chat + VRAM): [deploy-vllm-inference.md](deploy-vllm-inference.md)
- Rerank vLLM: [deploy-vllm-reranker.md](deploy-vllm-reranker.md)
- RAG consumer: [deploy-rag-query.md](deploy-rag-query.md)
