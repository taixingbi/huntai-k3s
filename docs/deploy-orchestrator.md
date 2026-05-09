# Deploy Orchestrator (dev)

Service image: [taixingbi/layer-orchestrator-v1](https://hub.docker.com/r/taixingbi/layer-orchestrator-v1) — source: [layer-orchestrator-v1](https://github.com/taixingbi/layer-orchestrator-v1)

The dev manifest exposes orchestrator on NodePort `30184` and ClusterIP port `8000`.

Key endpoints:

- `GET /health`
- `POST /orchestrator/answer` (JSON when `stream=false`, SSE when `stream=true`)

## Prerequisites

- Inference gateway running in `ai-dev` (`layer-gateway-inference:8000` or NodePort `30180`)
- RAG query running in `ai-dev` (`layer-rag-query:8000` or NodePort `30183`)
- Port map reference: `docs/port.md`

## 1) Configure env values

Edit `manifests/orchestrator/layer-orchestrator-dev.yaml` if you need non-default model/env settings. By default:

- `LLM_GATEWAY_BASE_URL=http://layer-gateway-inference:8000`
- `RAG_HTTP_BASE_URL=http://layer-rag-query:8000`
- `RAG_COLLECTION_BASE=taixing_knowledge`

## 2) Apply manifests

```bash
# optional: preload image on the node
sudo k3s ctr images pull docker.io/taixingbi/layer-orchestrator-v1:latest

sudo k3s kubectl apply -f manifests/orchestrator/layer-orchestrator-dev.yaml
sudo k3s kubectl rollout restart deployment/layer-orchestrator -n ai-dev
sudo k3s kubectl rollout status deployment/layer-orchestrator -n ai-dev
sudo k3s kubectl get pods,svc -n ai-dev -l app=layer-orchestrator -o wide
```

## 3) Smoke tests

Health check:

```bash
curl -sS http://192.168.86.179:30184/health | jq .
echo
```

Answer (non-stream):

```bash
curl -sS -X POST "http://192.168.86.179:30184/orchestrator/answer" \
  -H "Content-Type: application/json" \
  -H "X-Session-Id: ses-123" \
  -H "X-Request-Id: req-123" \
  -H "X-Trace-Id: req-123" \
  -H "X-User-Id: taixing" \
  -H "X-User-Roles: hr" \
  -H "X-User-Groups: engineering" \
  -H "X-User-Teams: rag-platform" \
  -d '{
    "question": "what is Taixing US visa status?"
  }' | jq .
echo
```

SSE answer stream (`stream: true`):

```bash
curl -N -sS -X POST "http://192.168.86.179:30184/orchestrator/answer" \
  -H "Content-Type: application/json" \
  -H "Accept: text/event-stream" \
  -H "X-Session-Id: ses-123" \
  -H "X-Request-Id: req-123" \
  -H "X-Trace-Id: req-123" \
  -H "X-User-Id: taixing" \
  -H "X-User-Roles: hr" \
  -H "X-User-Groups: engineering" \
  -H "X-User-Teams: rag-platform" \
  -d '{
    "question": "what is Taixing US visa status?",
    "stream": true
  }'
```

NodePort:

- dev: `30184`
