# Deploy Inference Gateway (dev)

Gateway image: [ghcr.io/taixingbi/layer-gateway-inference-v1](https://github.com/taixingbi/layer-gateway-inference-v1/pkgs/container/layer-gateway-inference-v1)

In-cluster: `http://layer-gateway-inference:8000` in `ai-dev`. LAN NodePort: `30180`; see `docs/port.md`.

## 1) Create secrets (required for `envFrom.secretRef`)

The dev overlay uses `envFrom.secretRef.name=layer-gateway-inference-secrets`.
Create the Secret in `ai-dev` before rollout.

```bash
mkdir -p ~/.secrets
chmod 700 ~/.secrets
printf '%s' 'sk-xxxxx' > ~/.secrets/openai.key
chmod 600 ~/.secrets/openai.key

sudo k3s kubectl create secret generic layer-gateway-inference-secrets -n ai-dev \
  --from-file=OPENAI_API_KEY="$HOME/.secrets/openai.key" \
  --dry-run=client -o yaml | sudo k3s kubectl apply -f -

# check config
sudo k3s kubectl -n ai-dev exec -it deploy/layer-gateway-inference -- cat /app/config.yaml

# check secret
sudo k3s kubectl get secret layer-gateway-inference-secrets -n ai-dev \
  -o jsonpath='{.data.OPENAI_API_KEY}' | base64 -d | wc -c
```

## 2) Deploy (Argo CD / GitOps)

Managed by `gateway-inference-dev` via [app-of-apps](deploy-gitops-argocd.md).

```bash
sudo k3s kubectl get application gateway-inference-dev -n argocd
sudo k3s kubectl get pods,svc -n ai-dev -l app=layer-gateway-inference
sudo k3s kubectl get svc -A -o wide | grep 30180
sudo k3s kubectl get pods -n ai-dev -l app=layer-gateway-inference -o wide
```

## 3) Version (`GET /version`)

Build metadata baked into the image at CI time; `environment` from `ENVIRONMENT` in the Deployment (`ai-dev`).

```bash
curl -sS http://192.168.86.179:30180/version | jq .
```

## 4) Readiness (`GET /ready`)

Probes each vLLM backend in `config.yaml` (`GET {url}/health`). Use for smoke tests and Kubernetes readiness (liveness stays on `/health`).

```bash
curl -sS http://192.168.86.179:30180/ready | jq .
```

Expected when both GPU nodes are up:

```json
{
  "status": "ready",
  "healthy_backends": 2,
  "total_backends": 2,
  "backends": {
    "gpu-node-1": "healthy",
    "gpu-node-2": "healthy"
  }
}
```

## 5) Example: `POST /v1/chat/completions`

From a host that can reach dev NodePort `30180`. Optional `conversation_id` in the JSON is for client-side correlation; omit it if your OpenAI-compatible backend rejects unknown fields.

```bash
curl http://192.168.86.179:30180/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "X-Request-Id: request-id-1" \
  -H "X-Trace-Id: trace-id-1" \
  -H "X-Session-Id: session-id-1" \
  -d '{
    "model": "Qwen/Qwen2.5-7B-Instruct",
    "conversation_id": "conv_456",
    "messages": [
      {"role": "user", "content": "where is jersey city"}
    ],
    "max_tokens": 50,
    "temperature": 0.7
  }' | jq .
echo
```

## 6) Example: `POST /v1/chat/completions` (stream)

Use `curl -N` so chunks print as they arrive. `stream: true` in the JSON body enables token streaming (same NodePort `30180`).

```bash
curl -N http://192.168.86.179:30180/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "X-Request-Id: request-id-stream-1" \
  -H "X-Trace-Id: trace-id-stream-1" \
  -H "X-Session-Id: session-id-stream-1" \
  -d '{
    "model": "Qwen/Qwen2.5-7B-Instruct",
    "messages": [
      {"role": "user", "content": "tell me 3 facts about jersey city"}
    ],
    "max_tokens": 80,
    "temperature": 0.7,
    "stream": true
  }'
```

Verify the response **`model`** is `Qwen/Qwen2.5-7B-Instruct` (not `gpt-4o-mini`). If you see OpenAI model ids, check gateway logs for `queue_age_fallback` (see §7).

## 7) Troubleshooting

| Symptom | Cause | Fix |
|---------|--------|-----|
| Chat returns `gpt-4o-mini-*` | `openai_fallback.enabled: true` and `queue_age_fallback` after `queue_max_age_ms` | Set `openai_fallback.enabled: false`; raise `queue_max_age_ms` (e.g. 30000) in [`configmap.yaml`](../manifests/gateway-inference/base/configmap.yaml); restart gateway |
| Gateway logs `queue_age_fallback` every ~2s | Scheduler did not assign a GPU backend before wait expired (often circuits open or duplicate backend URLs) | Per-node backend URLs (`:30080` on each GPU node); restart `layer-gateway-inference` to reset circuits |
| `GET /ready` OK but chat wrong | `/ready` only probes `GET /health`, not chat routing | §5 model check + gateway logs |
| Orchestrator `DecodingError` on `/ready` | LLM probe got non-JSON (often while fallback misconfigured) | Fix gateway chat path first; then `curl :30184/ready` |

After config change:

```bash
sudo k3s kubectl apply -k manifests/gateway-inference/overlays/dev
sudo k3s kubectl rollout restart deploy/layer-gateway-inference -n ai-dev
curl -sS http://192.168.86.179:30180/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen2.5-7B-Instruct","messages":[{"role":"user","content":"ping"}],"max_tokens":8}' \
  | jq '.model'
```

Verify the response **`model`** is `Qwen/Qwen2.5-7B-Instruct` (not `gpt-4o-mini`). If you see OpenAI model ids, check gateway logs for `queue_age_fallback` (see §7).

## 7) Troubleshooting

| Symptom | Cause | Fix |
|---------|--------|-----|
| Chat returns `gpt-4o-mini-*` | `openai_fallback.enabled: true` and `queue_age_fallback` after `queue_max_age_ms` | Set `openai_fallback.enabled: false`; raise `queue_max_age_ms` (e.g. 30000) in [`configmap.yaml`](../manifests/gateway-inference/base/configmap.yaml); restart gateway |
| Gateway logs `queue_age_fallback` every ~2s | Scheduler did not assign a GPU backend before wait expired (often circuits open or duplicate backend URLs) | Per-node backend URLs (`:30080` on each GPU node); restart `layer-gateway-inference` to reset circuits |
| `GET /ready` OK but chat wrong | `/ready` only probes `GET /health`, not chat routing | §5 model check + gateway logs |
| Orchestrator `DecodingError` on `/ready` | LLM probe got non-JSON (often while fallback misconfigured) | Fix gateway chat path first; then `curl :30184/ready` |

After config change:

```bash
sudo k3s kubectl apply -k manifests/gateway-inference/overlays/dev
sudo k3s kubectl rollout restart deploy/layer-gateway-inference -n ai-dev
curl -sS http://192.168.86.179:30180/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen2.5-7B-Instruct","messages":[{"role":"user","content":"ping"}],"max_tokens":8}' \
  | jq '.model'
```
