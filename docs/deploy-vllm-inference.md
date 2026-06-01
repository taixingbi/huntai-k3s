# Deploy vLLM Inference

```bash
sudo k3s kubectl apply -f manifests/ai/inference-qwen25-7b.yaml
sudo k3s kubectl get pods,svc -n ai -o wide
```

Important ports from this manifest:

- `vllm-inference` ClusterIP service: `8000`
- NodePort service `inference-qwen25-7b`: `30080`

## Router DPO LoRA adapter (optional)

After QLoRA DPO training ([`layer-router-dpo-v1/README.md`](../../layer-router-dpo-v1/README.md)), serve the adapter on the same vLLM deployment:

1. Copy the `adapter/` directory to a host path on the GPU node (e.g. `/data/models/router-dpo-v1/`).

2. Add volume mount + vLLM args on `inference-qwen25-7b` (example):

   ```yaml
   volumeMounts:
     - name: router-dpo
       mountPath: /models/router-dpo-v1
       readOnly: true
   volumes:
     - name: router-dpo
       hostPath:
         path: /data/models/router-dpo-v1
         type: Directory
   # container args (append):
   #   - --enable-lora
   #   - --max-lora-rank
   #   - "64"
   #   - --lora-modules
   #   - router-dpo-v1=/models/router-dpo-v1
   ```

3. Confirm the model id:

   ```bash
   curl -sS http://192.168.86.173:30080/v1/models | jq .
   ```

4. Point orchestrator eval or gateway requests at that id (`router_model` on `POST /v1/orchestrator/eval/router`, or `model` in chat completions).

**Merged weights (alternative):** use `export_merge.py` and set `--model` to the merged directory instead of `--enable-lora` (higher VRAM use on 16GB cards).
