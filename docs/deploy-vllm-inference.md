# Deploy vLLM Inference

```bash
sudo k3s kubectl apply -f manifests/ai/inference-qwen25-7b.yaml
sudo k3s kubectl get pods,svc -n ai -o wide
```

Important ports from this manifest:

- `vllm-inference` ClusterIP service: `8000`
- NodePort service `inference-qwen25-7b`: `30080`

## Router SFT / DPO LoRA adapters

After training in [`layer-router-train-v1`](../../layer-router-train-v1/README.md), adapters are uploaded to Hugging Face with LoRA files at **repo root** (vLLM-compatible). The manifest loads them via static `--lora-modules`:

| Model id | HF repo |
|----------|---------|
| `router-qwen2.5-7b-sft-v1.00` | `taixingbi/router-qwen2.5-7b-sft-v1.00` |
| `router-qwen2.5-7b-dpo-v1.00` | `taixingbi/router-qwen2.5-7b-dpo-v1.00` |

Base model remains `Qwen/Qwen2.5-7B-Instruct`. Re-upload existing HF repos after the `hf_upload.py` fix if they still have an `adapter/` subfolder.

Verify after rollout:

```bash
curl -sS http://192.168.86.173:30080/v1/models | jq '.data[].id'
```

Point orchestrator eval at a LoRA id via `router_model` on `POST /v1/orchestrator/eval/router` (production `LLM_MODEL` stays on the base model).

**Merged weights (alternative):** use `export_merge.py` and set `--model` to the merged directory instead of `--enable-lora` (higher VRAM use on 16GB cards).
