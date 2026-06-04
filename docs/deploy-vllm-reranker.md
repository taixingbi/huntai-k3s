# Deploy vLLM reranker (BAAI/bge-reranker-v2-m3)

Cross-encoder reranking runs **inside the per-GPU vLLM bundle** on port **8002**. It is **not** a separate Deployment — one `vllm serve` process per bundle Pod, after embed (`:8001`) and before chat (`:8000`). Bundle overview: [deploy-vllm-inference.md](deploy-vllm-inference.md). Client-facing routing: [deploy-gateway-reranker.md](deploy-gateway-reranker.md) (NodePort **30182**).

GitOps: Argo CD Application **`vllm-inference`** (`manifests/vllm`). Cutover runbook: [fix-vllm-plane-cutover.md](fix-vllm-plane-cutover.md). Startup script: ConfigMap **`vllm-bundle-start`** → [`manifests/vllm/vllm-bundle-start-configmap.yaml`](../manifests/vllm/vllm-bundle-start-configmap.yaml).

## Layout

| Item | Value |
|------|--------|
| Model | `BAAI/bge-reranker-v2-m3` |
| Port (in Pod) | **8002** |
| API | `POST /v1/rerank` (OpenAI-style rerank) |
| GPU util (default) | `0.05` |
| `max-model-len` | `512` |
| Start order | **Second** (after embed `/health`, before chat) |

Per-node ClusterIP Services (namespace **`vllm`**, gateway backends):

| Service | Backend |
|---------|---------|
| `vllm-rerank-gpu-node-1` | `gpu-node-1` bundle Pod |
| `vllm-rerank-gpu-node-2` | `gpu-node-2` bundle Pod |

LAN smoke tests: NodePort **`30082`** on **`rerank-bge-m3`** (same pattern as chat **`30080`**). Production clients use the **reranker gateway** on **30182**.

Reranker gateway **`RERANK_BACKENDS`** (in `manifests/gateway-reranker/base/deployment.yaml`):

```text
reranker-node-1=http://vllm-rerank-gpu-node-1.vllm.svc.cluster.local:8002
reranker-node-2=http://vllm-rerank-gpu-node-2.vllm.svc.cluster.local:8002
```

## `vllm serve` flags

Rerank/score pooling models **auto-detect** on current vLLM images; no `--runner` override is required in the bundle:

```bash
vllm serve BAAI/bge-reranker-v2-m3 \
  --host 0.0.0.0 --port 8002 \
  --gpu-memory-utilization 0.05 \
  --max-model-len 512
```

Edit the ConfigMap and push to `main`; bump **`huntai.ai/vllm-bundle-start-revision`** or `rollout restart` after script changes. See [deploy-vllm-inference.md § ConfigMap changes](deploy-vllm-inference.md#configmap-changes-require-a-pod-restart).

## Rollout and readiness

Embed must pass `/health` before rerank starts; chat starts only after rerank passes `/health`. Full bundle rollout can take **10–45 minutes** per GPU node on cold cache.

```bash
sudo k3s kubectl get pods -n vllm -l app=vllm-bundle -o wide
sudo k3s kubectl rollout status deploy/vllm-bundle-gpu-node-1 -n vllm --timeout=45m
sudo k3s kubectl rollout status deploy/vllm-bundle-gpu-node-2 -n vllm --timeout=45m
sudo k3s kubectl exec -n vllm deploy/vllm-bundle-gpu-node-1 -- python3 /scripts/healthcheck.py
```

**Pass:** `ok rerank http://127.0.0.1:8002/health` (and embed/chat lines; embed also requires `ok embed /v1/embeddings`).

Confirm live script:

```bash
sudo k3s kubectl exec -n vllm deploy/vllm-bundle-gpu-node-1 -- \
  grep -A5 'starting rerank' /scripts/start-vllm-bundle.sh
```

## Smoke tests

Run after both bundle Pods are **`1/1 Ready`**. GPU node-1 rerank NodePort: **`192.168.86.173:30082`**. `jq` is optional.

### 2) Rerank — NodePort `30082`

```bash
curl -sS http://192.168.86.173:30082/health | jq .
echo
curl -sS http://192.168.86.173:30082/v1/models | jq '.data[].id'
echo
curl -sS -X POST http://192.168.86.173:30082/v1/rerank \
  -H "Content-Type: application/json" \
  -d '{
    "model": "BAAI/bge-reranker-v2-m3",
    "query": "what is taixing visa",
    "documents": [
      "Taixing holds an active US work visa.",
      "Unrelated sentence about weather."
    ],
    "top_n": 2
  }' | jq
echo
```

```bash
curl -sS http://192.168.86.176:30082/health | jq .
echo
curl -sS http://192.168.86.176:30082/v1/models | jq '.data[].id'
echo
curl -sS -X POST http://192.168.86.176:30082/v1/rerank \
  -H "Content-Type: application/json" \
  -d '{
    "model": "BAAI/bge-reranker-v2-m3",
    "query": "what is taixing visa",
    "documents": [
      "Taixing holds an active US work visa.",
      "Unrelated sentence about weather."
    ],
    "top_n": 2
  }' | jq
echo
```

**Pass:** `/health` ok; `/v1/models` lists `BAAI/bge-reranker-v2-m3`; rerank returns **`results: 2`**, `model` set, non-empty `usage`. Via gateway: [deploy-gateway-reranker.md](deploy-gateway-reranker.md) (`30182`).

## Troubleshooting

| Symptom | Likely cause | Action |
|---------|----------------|--------|
| Rerank never starts | Embed stuck or failed | Fix embed first: [deploy-vllm-embedding.md](deploy-vllm-embedding.md) |
| **`/v1/rerank` 4xx/5xx** | Model not loaded or OOM | Check bundle logs; lower chat util if GPU full |
| Gateway errors, Pod `/health` ok | Gateway backend URL or circuit breaker | Confirm `RERANK_BACKENDS` DNS; gateway logs |
| RAG retrieval poor / empty | Rerank or embed downstream | Test gateway **30181** and **30182**, then RAG [deploy-rag-query.md](deploy-rag-query.md) |

Logs:

```bash
sudo k3s kubectl logs -n vllm deploy/vllm-bundle-gpu-node-1 -c vllm-bundle --tail=100
```

Gateway readiness (proxies to vLLM **`/health`** only):

```bash
curl -sS http://192.168.86.179:30182/ready | jq .
```

## Observability

Prometheus scrapes **`vllm-rerank-gpu-node-*`** with label **`workload=reranker`**. Grafana: `grafana-import/dashboard/reranker.json` (via gateway metrics and vLLM targets — see [deploy-gateway-reranker.md](deploy-gateway-reranker.md)).

RAG uses **`RERANK_URL=http://layer-gateway-reranker:8000`** and **`RERANK_MODEL=BAAI/bge-reranker-v2-m3`** ([deploy-rag-query.md](deploy-rag-query.md)).

## Related

- Bundle (chat + VRAM): [deploy-vllm-inference.md](deploy-vllm-inference.md)
- Embed vLLM: [deploy-vllm-embedding.md](deploy-vllm-embedding.md)
- RAG consumer: [deploy-rag-query.md](deploy-rag-query.md)
