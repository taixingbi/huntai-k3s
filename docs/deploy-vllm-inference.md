# Deploy vLLM (chat + embed + rerank bundle)

GitOps: Argo CD Application `vllm-inference` (manifest path `manifests/ai`). Bootstrap via [deploy-gitops-argocd.md](deploy-gitops-argocd.md).

Each GPU node runs **one Pod** (`vllm-bundle-gpu-node-1` / `vllm-bundle-gpu-node-2`) with **one container** and **three vLLM processes** on a single GPU (scheme C1):

| Port | Role | Model |
|------|------|--------|
| 8000 | chat | `Qwen/Qwen2.5-7B-Instruct` + router LoRAs (see below) |
| 8001 | embed | `BAAI/bge-m3` (`--runner pooling` + `--hf-overrides` for `BgeM3EmbeddingModel`) |
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

## Hugging Face cache (hostPath)

Each GPU node keeps model downloads on disk so Pod restarts skip multi‑minute HF pulls. Before first rollout (on **both** `gpu-node-1` and `gpu-node-2`):

```bash
sudo mkdir -p /data/hf-cache
sudo chmod 1777 /data/hf-cache   # or chown to the user the container runs as
```

The bundle mounts `hostPath: /data/hf-cache` → `/root/.cache/huggingface` and sets `HF_HOME` to that path. Allow **~50–80GiB** free per node (Qwen + bge-m3 + reranker). If you previously ran vLLM on the host, you can bind the existing cache directory instead of an empty `/data/hf-cache`.

**InitContainer `prefetch-hf-cache`** runs before the GPU container: `snapshot_download` for embed/rerank/chat (and optional router LoRAs when `PREFETCH_ROUTER_LORAS=true`) into the same hostPath. Skips re-download when blobs already exist; first cold node still needs network time but vLLM no longer pulls weights during GPU startup.

```bash
sudo k3s kubectl logs -n ai -l vllm-node=gpu-node-1 -c prefetch-hf-cache
```

For gated Hub repos, add `HF_TOKEN` to the init and main container (Secret optional).

## GPU memory (conservative defaults)

`--gpu-memory-utilization` is a vLLM soft limit, not Kubernetes isolation:

| Process | util | Notes |
|---------|------|--------|
| chat | 0.84 | Base Qwen + 2 router LoRAs; `max-model-len` 2048, `max-num-seqs` 1, `--enforce-eager` |
| embed | 0.08 | Started first; waits up to 40m for `/health` |
| rerank | 0.05 | Waits up to 30m after embed ready |

Chat starts only after embed and rerank pass `/health`. Each process uses util × **total** VRAM; on a 24GB 3090 with siblings loaded, util above ~0.84 can fail init (`Free memory ... less than desired`). Edit the ConfigMap script and roll out; any script change restarts the whole bundle on that node.

If chat still fails: lower util (0.78–0.82), lower embed/rerank util, or disable LoRA temporarily.

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

### ConfigMap changes require a Pod restart

Updating `vllm-bundle-start` **does not reload** running bundle Pods (scripts are mounted at Pod start). After Argo syncs a script change, roll both Deployments (or bump `huntai.ai/vllm-bundle-start-revision` on the Pod template):

```bash
sudo k3s kubectl rollout restart deploy/vllm-bundle-gpu-node-1 deploy/vllm-bundle-gpu-node-2 -n ai
sudo k3s kubectl rollout status deploy/vllm-bundle-gpu-node-1 -n ai --timeout=45m
sudo k3s kubectl rollout status deploy/vllm-bundle-gpu-node-2 -n ai --timeout=45m
```

`healthcheck.py` now probes `POST /v1/embeddings` on `:8001` so a Pod is not Ready when embed returns **501** (`The model does not support Embeddings API`). That usually means the bundle is still on an old start script — restart as above. Embed must use **`--runner pooling`** plus **`BgeM3EmbeddingModel`** hf-overrides (see ConfigMap).

**Rollback:** revert Git commit; optionally restart host vLLM on previous ports.

## Router SFT / DPO LoRA adapters

Chat loads two LoRA adapters via `--enable-lora` in `vllm-bundle-start-configmap.yaml`:

| Model id | HF repo |
|----------|---------|
| `router-qwen2.5-7b-sft-v1.00` | `taixingbi/router-qwen2.5-7b-sft-v1.00` |
| `router-qwen2.5-7b-dpo-v1.00` | `taixingbi/router-qwen2.5-7b-dpo-v1.00` |

Orchestrator **`ROUTER_MODEL`** defaults to `router-qwen2.5-7b-sft-v1.00` (override per request with `router_model` on eval). General chat/RAG synthesis still uses `Qwen/Qwen2.5-7B-Instruct`.

Verify after rollout:

```bash
curl -sS http://192.168.86.173:30080/v1/models | jq '.data[].id'
```

Expect base Qwen plus both router LoRA ids. If init fails with `Free memory ... less than desired`, lower chat util to 0.82 or disable LoRA.

**Merged weights (alternative):** `export_merge.py` and point chat `--model` at merged weights instead of `--enable-lora`.

## Image pin

Manifest uses `vllm/vllm-openai:latest`. Pin a fixed tag or digest in `vllm-bundle.yaml` after validating `vllm serve` flags on your cluster.
