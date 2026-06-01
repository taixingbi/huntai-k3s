# Deploy Inference Gateway (dev/prod)

Gateway image: [taixingbi/layer-gateway-inference-v1](https://hub.docker.com/r/taixingbi/layer-gateway-inference-v1)

In-cluster: `http://layer-gateway-inference:8000` (dev `ai-dev`, prod `ai-prod`). LAN NodePorts: `30180` (dev), `30380` (prod); see `docs/port.md`.

## 1) Create secrets (required for `envFrom.secretRef`)

Both manifests use `envFrom.secretRef.name=layer-gateway-inference-secrets`.
Create the Secret in each namespace you deploy to.

```bash
mkdir -p ~/.secrets
chmod 700 ~/.secrets
printf '%s' 'sk-xxxxx' > ~/.secrets/openai.key
chmod 600 ~/.secrets/openai.key

# dev
sudo k3s kubectl create secret generic layer-gateway-inference-secrets -n ai-dev \
  --from-file=OPENAI_API_KEY="$HOME/.secrets/openai.key" \
  --dry-run=client -o yaml | sudo k3s kubectl apply -f -

# prod
sudo k3s kubectl create secret generic layer-gateway-inference-secrets -n ai-prod \
  --from-file=OPENAI_API_KEY="$HOME/.secrets/openai.key" \
  --dry-run=client -o yaml | sudo k3s kubectl apply -f -

# check config
sudo k3s kubectl -n ai-dev exec -it deploy/layer-gateway-inference -- cat /app/config.yaml
sudo k3s kubectl -n ai-prod exec -it deploy/layer-gateway-inference -- cat /app/config.yaml

# check secret
sudo k3s kubectl get secret layer-gateway-inference-secrets -n ai-dev \
  -o jsonpath='{.data.OPENAI_API_KEY}' | base64 -d | wc -c

sudo k3s kubectl get secret layer-gateway-inference-secrets -n ai-prod \
  -o jsonpath='{.data.OPENAI_API_KEY}' | base64 -d | wc -c
```

## 2) Deploy manifests

```bash
# dev (Argo CD / GitOps source)
sudo k3s kubectl apply -f argocd/applications/gateway-inference-dev.yaml
sudo k3s kubectl get application gateway-inference-dev -n argocd
sudo k3s kubectl get pods,svc -n ai-dev -l app=layer-gateway-inference
sudo k3s kubectl get svc -A -o wide | grep 30180
sudo k3s kubectl get pods -n ai-dev -l app=layer-gateway-inference -o wide

# prod
sudo k3s kubectl rollout restart deployment/layer-gateway-inference -n ai-prod
sudo k3s kubectl apply -f manifests/gateway/layer-gateway-inference-prod.yaml
sudo k3s kubectl get pods,svc -n ai-prod -l app=layer-gateway-inference
sudo k3s kubectl get svc -A -o wide | grep 30380
sudo k3s kubectl get pods -n ai-prod -l app=layer-gateway-inference -o wide
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

## 5) Example: `POST /v1/chat/completions` (dev)

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

## 6) Example: `POST /v1/chat/completions` (stream, dev)

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

NodePorts:

- dev: `30180`
- prod: `30380`
