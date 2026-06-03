# Deploy vLLM (chat + embed + rerank bundle)

GitOps: Argo CD Application `vllm-inference` (manifest path `manifests/ai`). Bootstrap via [deploy-gitops-argocd.md](deploy-gitops-argocd.md).

Each GPU node runs **one Pod** (`vllm-bundle-gpu-node-1` / `vllm-bundle-gpu-node-2`) with **one container** and **three vLLM processes** on a single GPU (scheme C1):

| Port | Role | Model |
|------|------|--------|
| 8000 | chat | `Qwen/Qwen2.5-7B-Instruct` + LoRA |
| 8001 | embed | `BAAI/bge-m3` (pooling; `--hf-overrides` for `BgeM3EmbeddingModel`) |
| 8002 | rerank | `BAAI/bge-reranker-v2-m3` (`/v1/rerank`; vLLM 0.22 auto-detect) |

Startup script: ConfigMap `vllm-bundle-start` → [`manifests/ai/vllm-bundle-start-configmap.yaml`](../manifests/ai/vllm-bundle-start-configmap.yaml).

```bash
sudo k3s kubectl get application vllm-inference -n argocd
sudo k3s kubectl get pods,svc -n ai -l app=vllm-bundle -o wide
sudo k3s kubectl logs -n ai -l vllm-node=gpu-node-1 -f --tail=100
```

## Services

| Service | Port | Notes |
|---------|------|--------|
| `vllm-inference` | 8000 | Chat; used by inference gateway |
| `inference-qwen25-7b` | 8000 (NodePort **30080**) | LAN smoke tests |
| `vllm-embed-gpu-node-{1,2}` | 8001 | Embedding gateway backends |
| `vllm-rerank-gpu-node-{1,2}` | 8002 | Reranker gateway backends |

## GPU memory (conservative defaults)

`--gpu-memory-utilization` is a vLLM soft limit, not Kubernetes isolation. Initial values (tune up after stable `nvidia-smi`):

| Process | util | Notes |
|---------|------|--------|
| chat | 0.84 | `max-model-len` 2048, `max-num-seqs` 1, `--enforce-eager`, `max-loras` 2; must fit **free** VRAM after embed/rerank (~0.84 on 24GB, not 0.86) |
| embed | 0.08 | Started first |
| rerank | 0.05 | Started first |

Each vLLM process applies `gpu-memory-utilization` to **full** VRAM, not “what is left” after siblings. On a 24GB 3090, chat weights are ~15.5GiB; with embed+rerank already loaded, chat at 0.50 left no KV blocks (`Available KV cache memory: -8.31 GiB`). Edit the ConfigMap script and roll out; any script change restarts the whole bundle on that node.

If chat fails at init with `Free memory ... is less than desired GPU memory utilization`, lower chat util (try 0.82) or embed/rerank util. If it fails after load with `No available memory for the cache blocks`, disable LoRA temporarily or run chat-only on one GPU node.

## Migration from host / old chat Deployment

Before the first successful bundle rollout:

1. **Stop** host vLLM on GPU nodes (`:8001`, `:8002`, and any host chat using the GPU).
2. Let Argo delete old `inference-qwen25-7b` Pods so GPUs are free.
3. Sync `vllm-inference`; wait for `startupProbe` (model pull can take 15–30+ minutes).
4. Verify all three ports on each node:

```bash
curl -sf http://192.168.86.173:30080/health && echo " chat ok"
sudo k3s kubectl exec -n ai deploy/vllm-bundle-gpu-node-1 -- python3 /scripts/healthcheck.py
```

5. Confirm embedding/rerank gateways: `curl http://192.168.86.179:30181/ready` and `30182/ready`.

**Rollback:** revert Git commit; optionally restart host vLLM on previous ports.

## Router SFT / DPO LoRA adapters

After training in [`layer-router-train-v1`](../../layer-router-train-v1/README.md), adapters are on Hugging Face at **repo root** (vLLM-compatible). Loaded via `--lora-modules` in the bundle script:

| Model id | HF repo |
|----------|---------|
| `router-qwen2.5-7b-sft-v1.00` | `taixingbi/router-qwen2.5-7b-sft-v1.00` |
| `router-qwen2.5-7b-dpo-v1.00` | `taixingbi/router-qwen2.5-7b-dpo-v1.00` |

Verify after rollout:

```bash
curl -sS http://192.168.86.173:30080/v1/models | jq '.data[].id'
```

Point orchestrator eval at a LoRA id via `router_model` on `POST /v1/orchestrator/eval/router` (production `LLM_MODEL` stays on the base model).

**Merged weights (alternative):** use `export_merge.py` and set chat `--model` to the merged directory instead of `--enable-lora` (higher VRAM use).

## Image pin

Manifest uses `vllm/vllm-openai:latest`. Pin a fixed tag or digest in `vllm-bundle.yaml` after validating `vllm serve` flags on your cluster.
