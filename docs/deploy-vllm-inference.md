# Deploy vLLM (chat + embed + rerank bundle)

GitOps: Argo CD Application `vllm-inference` (manifest path `manifests/vllm`). Bootstrap via [deploy-gitops-argocd.md](deploy-gitops-argocd.md).

Each GPU node runs **one Pod** (`vllm-bundle-gpu-node-1` / `vllm-bundle-gpu-node-2`) with **one container** and **three vLLM processes** on a single GPU (scheme C1). **This doc covers the bundle and chat (`:8000`).** Embed and rerank are documented separately:

- [deploy-vllm-embedding.md](deploy-vllm-embedding.md) — `BAAI/bge-m3` on `:8001`
- [deploy-vllm-reranker.md](deploy-vllm-reranker.md) — `BAAI/bge-reranker-v2-m3` on `:8002`

| Port | Role | Doc |
|------|------|-----|
| 8000 | chat (`Qwen/Qwen2.5-7B-Instruct` + router LoRAs) | below |
| 8001 | embed | [deploy-vllm-embedding.md](deploy-vllm-embedding.md) |
| 8002 | rerank | [deploy-vllm-reranker.md](deploy-vllm-reranker.md) |

Startup script: ConfigMap `vllm-bundle-start` → [`manifests/vllm/vllm-bundle-start-configmap.yaml`](../manifests/vllm/vllm-bundle-start-configmap.yaml).

```bash
sudo k3s kubectl get application vllm-inference -n argocd
sudo k3s kubectl get pods,svc -n vllm -l app=vllm-bundle -o wide
sudo k3s kubectl logs -n vllm -l vllm-node=gpu-node-1 -f --tail=100
```

## Services (chat)

| Service | Port | Notes |
|---------|------|--------|
| `vllm-inference` | 8000 | Chat; used by inference gateway |
| `inference-qwen25-7b` | 8000 (NodePort **30080**) | LAN smoke tests |

Embed/rerank NodePorts and per-node ClusterIP Services (`vllm-embed-gpu-node-*`, `vllm-rerank-gpu-node-*`) are in the dedicated docs above.

## Hugging Face cache (hostPath)

Each GPU node keeps model downloads on disk so Pod restarts skip multi‑minute HF pulls. Before first rollout (on **both** `gpu-node-1` and `gpu-node-2`):

```bash
sudo mkdir -p /data/hf-cache
sudo chmod 1777 /data/hf-cache   # or chown to the user the container runs as
```

The bundle mounts `hostPath: /data/hf-cache` → `/root/.cache/huggingface` and sets `HF_HOME` to that path. Allow **~50–80GiB** free per node (all three models). If you previously ran vLLM on the host, you can bind the existing cache directory instead of an empty `/data/hf-cache`.

**InitContainer `prefetch-hf-cache`** runs before the GPU container: `snapshot_download` for chat (and embed/rerank; optional router LoRAs when `PREFETCH_ROUTER_LORAS=true`) into the same hostPath. Skips re-download when blobs already exist; first cold node still needs network time but vLLM no longer pulls weights during GPU startup.

```bash
sudo k3s kubectl logs -n vllm -l vllm-node=gpu-node-1 -c prefetch-hf-cache
```

For gated Hub repos, add `HF_TOKEN` to the init and main container (Secret optional).

## GPU memory (chat)

`--gpu-memory-utilization` is a vLLM soft limit, not Kubernetes isolation. Chat shares the GPU with embed and rerank (see their docs for util defaults). Chat defaults:

| Setting | Value |
|---------|--------|
| `gpu-memory-utilization` | 0.84 |
| `max-model-len` | 2048 |
| `max-num-seqs` | 1 |
| LoRA | 2 router adapters, `--enforce-eager` |

Chat starts only after embed and rerank pass `/health` in the bundle script. On a 24GB 3090 with siblings loaded, chat util above ~0.84 can fail init (`Free memory ... less than desired`). Edit the ConfigMap script and roll out; any script change restarts the whole bundle on that node.

If chat still fails: lower util (0.78–0.82), lower embed/rerank util ([embed](deploy-vllm-embedding.md) / [rerank](deploy-vllm-reranker.md) docs), or disable LoRA temporarily.

## Migration from host / old chat Deployment

Before the first successful bundle rollout:

1. **Stop** host vLLM on GPU nodes (any process using the GPU).
2. Remove legacy Deployments/ReplicaSets (pre-bundle `vllm` Deployment / RS — not in Git):

   ```bash
   ./scripts/cleanup-legacy-vllm.sh
   ```

3. Sync `vllm-inference` (enable **Prune**). If sync errors with *“synchronization tasks are not valid”*, update AppProjects (`argocd/projects/*.yaml` must allow `Namespace`) and re-run `./scripts/bootstrap-argocd.sh`, then sync again.

4. Wait for `startupProbe` (model pull can take 15–30+ minutes).
4. Run [§ Smoke tests](#smoke-tests) below, then embed/rerank smokes in their docs.

## Namespace rename (`ai` → `vllm`)

Full step-by-step (gateways, Prometheus, Grafana): **[fix-vllm-plane-cutover.md](fix-vllm-plane-cutover.md)**.

Inference manifests live under `manifests/vllm/` and deploy into namespace **`vllm`**. Application tier (gateways, RAG, Qdrant, web) stays in **`ai-dev`**.

After `main` updates and Argo syncs `vllm-inference`:

```bash
sudo k3s kubectl get application vllm-inference -n argocd
sudo k3s kubectl get pods,svc -n vllm -l app=vllm-bundle -o wide
# Gateways must reach *.vllm.svc.cluster.local — restart if they still point at .ai.svc
sudo k3s kubectl rollout restart deploy/layer-gateway-embedding deploy/layer-gateway-reranker -n ai-dev
# When vllm is healthy and ai is empty, remove the old namespace (optional)
sudo k3s kubectl get all -n ai
sudo k3s kubectl delete namespace ai   # only if nothing needed remains
```

HostPath model caches are unchanged (same node paths; Pod names unchanged).

### ConfigMap changes require a Pod restart

Updating `vllm-bundle-start` **does not reload** running bundle Pods (scripts are mounted at Pod start). After Argo syncs a script change, roll both Deployments (or bump `huntai.ai/vllm-bundle-start-revision` on the Pod template):

```bash
sudo k3s kubectl rollout restart deploy/vllm-bundle-gpu-node-1 deploy/vllm-bundle-gpu-node-2 -n vllm
sudo k3s kubectl rollout status deploy/vllm-bundle-gpu-node-1 -n vllm --timeout=45m
sudo k3s kubectl rollout status deploy/vllm-bundle-gpu-node-2 -n vllm --timeout=45m
```

**Rollback:** revert Git commit; optionally restart host vLLM on previous ports.

## Smoke tests

Run from a host with cluster access after both bundle Pods are **`1/1 Ready`**. GPU node-1 chat NodePort: **`192.168.86.173:30080`**. `jq` is optional.

### Prerequisites

```bash
sudo k3s kubectl get pods -n vllm -l app=vllm-bundle -o wide
sudo k3s kubectl rollout status deploy/vllm-bundle-gpu-node-1 -n vllm --timeout=45m
sudo k3s kubectl rollout status deploy/vllm-bundle-gpu-node-2 -n vllm --timeout=45m
```

**Pass:** both Pods **`READY 1/1`**, **`AGE`** stable (not restarting).

### 1) Bundle healthcheck

All three processes (including embed API probe on `:8001`):

```bash
sudo k3s kubectl exec -n vllm deploy/vllm-bundle-gpu-node-1 -- python3 /scripts/healthcheck.py
sudo k3s kubectl exec -n vllm deploy/vllm-bundle-gpu-node-2 -- python3 /scripts/healthcheck.py
```

**Pass:** exit **0**. Embed failures → [deploy-vllm-embedding.md](deploy-vllm-embedding.md).

### 2) Chat — NodePort `30080`

```bash
curl -sS http://192.168.86.173:30080/health | jq .
echo
curl -sS http://192.168.86.173:30080/v1/models | jq '.data[].id'
echo
curl -sS http://192.168.86.173:30080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-7B-Instruct",
    "messages": [{"role": "user", "content": "Reply with one word: ok"}],
    "max_tokens": 8,
    "temperature": 0
  }' | jq '{model, answer: .choices[0].message.content}'
echo
```

```bash
curl -sS http://192.168.86.176:30080/health | jq .
echo
curl -sS http://192.168.86.176:30080/v1/models | jq '.data[].id'
echo
curl -sS http://192.168.86.176:30080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-7B-Instruct",
    "messages": [{"role": "user", "content": "Reply with one word: ok"}],
    "max_tokens": 8,
    "temperature": 0
  }' | jq '{model, answer: .choices[0].message.content}'
echo
```

**Pass:** `/health` ok; `/v1/models` lists `Qwen/Qwen2.5-7B-Instruct` (and router LoRA ids when enabled); chat returns non-empty `answer` and `model` is Qwen (not an OpenAI id). Via gateway: [deploy-gateway-inference.md](deploy-gateway-inference.md) (`30180`).

### 3) Router LoRA — SFT (`router-qwen2.5-7b-sft-v1.00`)

Use the **vLLM LoRA id** as `model` (not the Hugging Face repo path). The router expects **`system` + `user`** messages — same shape as orchestrator intent routing ([`router-v2.01-compact.txt`](../../layer-orchestrator-v1/app/prompts/router-v2.01-compact.txt), `__CANDIDATE_NAME__` → `Taixing Bi`). Orchestrator default **`ROUTER_MODEL`**.

```bash
ROUTER_PROMPT="$(sed 's/__CANDIDATE_NAME__/Taixing Bi/g' \
  ../layer-orchestrator-v1/app/prompts/router-v2.01-compact.txt)"

curl -sS http://192.168.86.173:30080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d "$(jq -n \
    --arg model "router-qwen2.5-7b-sft-v1.00" \
    --arg sys "$ROUTER_PROMPT" \
    '{
      model: $model,
      messages: [
        {role: "system", content: $sys},
        {role: "user", content: "What is Taixing Bi US visa status?"}
      ],
      max_tokens: 256,
      temperature: 0
    }')" \
  | jq -r '.choices[0].message.content' \
  | jq '{route, rewritten_question, confidence, reason}'
echo
```

**Pass:** valid JSON; **`route`** is **`rag_private_kb`**; non-empty **`rewritten_question`**. Response **`model`** (on the outer completion) is `router-qwen2.5-7b-sft-v1.00`. Full pipeline: [deploy-orchestrator.md §4.4](deploy-orchestrator.md#44-post-orchestratorevalrouter-optional) with `"router_model": "router-qwen2.5-7b-sft-v1.00"`.

### 4) Router LoRA — DPO (`router-qwen2.5-7b-dpo-v1.00`)

Same prompt and question; change only the LoRA **`model`** id.

```bash
ROUTER_PROMPT="$(sed 's/__CANDIDATE_NAME__/Taixing Bi/g' \
  ../layer-orchestrator-v1/app/prompts/router-v2.01-compact.txt)"

curl -sS http://192.168.86.173:30080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d "$(jq -n \
    --arg model "router-qwen2.5-7b-dpo-v1.00" \
    --arg sys "$ROUTER_PROMPT" \
    '{
      model: $model,
      messages: [
        {role: "system", content: $sys},
        {role: "user", content: "What is Taixing Bi US visa status?"}
      ],
      max_tokens: 256,
      temperature: 0
    }')" \
  | jq -r '.choices[0].message.content' \
  | jq '{route, rewritten_question, confidence, reason}'
echo
```

**Pass:** valid JSON; **`route`** is **`rag_private_kb`**. Orchestrator eval: §4.4 with `"router_model": "router-qwen2.5-7b-dpo-v1.00"`.

Embed and rerank smokes: [deploy-vllm-embedding.md](deploy-vllm-embedding.md), [deploy-vllm-reranker.md](deploy-vllm-reranker.md). Gateways and RAG: [deploy-gateway-embedding.md](deploy-gateway-embedding.md) (`30181`), [deploy-gateway-reranker.md](deploy-gateway-reranker.md) (`30182`), [deploy-rag-query.md](deploy-rag-query.md) (`30183`).

## Router SFT / DPO LoRA adapters

Chat loads two LoRA adapters via `--enable-lora` in `vllm-bundle-start-configmap.yaml`:

| Model id | HF repo |
|----------|---------|
| `router-qwen2.5-7b-sft-v1.00` | `taixingbi/router-qwen2.5-7b-sft-v1.00` |
| `router-qwen2.5-7b-dpo-v1.00` | `taixingbi/router-qwen2.5-7b-dpo-v1.00` |

Orchestrator **`ROUTER_MODEL`** defaults to `router-qwen2.5-7b-sft-v1.00` (override per request with `router_model` on eval). General chat/RAG synthesis still uses `Qwen/Qwen2.5-7B-Instruct`.

After rollout, **`/v1/models`** in §2 should list base Qwen plus both LoRA ids; confirm each adapter with §3 (SFT) and §4 (DPO). If init fails with `Free memory ... less than desired`, lower chat util to 0.82 or disable LoRA.

**Merged weights (alternative):** `export_merge.py` and point chat `--model` at merged weights instead of `--enable-lora`.

## Image pin

Manifest uses `vllm/vllm-openai:latest`. Pin a fixed tag or digest in `vllm-bundle.yaml` after validating `vllm serve` flags on your cluster.
