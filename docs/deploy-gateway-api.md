# Deploy Gateway API (dev)

Service image: [taixingbi/layer-gateway-api-v1](https://hub.docker.com/r/taixingbi/layer-gateway-api-v1) — source: [layer-gateway-api-v1](https://github.com/taixingbi/layer-gateway-api-v1)

The dev manifest exposes the gateway on NodePort **`30185`**; orchestrator remains **`30184`** (see `docs/port.md`). In-cluster callers use `http://layer-gateway-api:8000` in `ai-dev`.

The gateway validates stub auth, normalizes chat requests, calls the orchestrator (`flat_headers` contract → `X-User-*` on upstream), and exposes `GET /health`, `GET /ready` (orchestrator probe), `GET /metrics`, `POST /api/chat`, and feedback routes per upstream README.

## Prerequisites

- Orchestrator running in `ai-dev` (`layer-orchestrator:8000` or NodePort `30184`). If orchestrator is down, `GET /ready` on gateway-api returns **503** (unless you disable the probe upstream with `ORCHESTRATOR_READINESS_PROBE_ENABLED=false`).
- Port map: `docs/port.md` (`30185` dev).

## 1) Configure env (optional)

Defaults are set in `manifests/gateway/layer-gateway-api-dev.yaml` (`ORCHESTRATOR_BASE_URL=http://layer-orchestrator:8000`, `ORCHESTRATOR_CONTRACT=flat_headers`, stub auth). Edit the manifest for different stub user fields, timeouts, or `MAX_INFLIGHT_REQUESTS`. Full variable list: upstream [`.env.example`](https://github.com/taixingbi/layer-gateway-api-v1/blob/main/.env.example).

## 2) Apply manifests

```bash
# optional: preload image on the node
sudo k3s ctr images pull docker.io/taixingbi/layer-gateway-api-v1:latest

sudo k3s kubectl apply -f manifests/gateway/layer-gateway-api-dev.yaml
sudo k3s kubectl rollout restart deployment/layer-gateway-api -n ai-dev
sudo k3s kubectl rollout status deployment/layer-gateway-api -n ai-dev
sudo k3s kubectl get pods,svc -n ai-dev -l app=layer-gateway-api -o wide
sudo k3s kubectl get svc -A -o wide | grep 30185
```

## 3) Smoke tests

From a host that can reach NodePort `30185` (adjust IP if your server differs). `jq` is optional for JSON responses (drop `| jq .` if not installed).

Health, ready, and metrics:

```bash
curl -sS http://192.168.86.179:30185/health | jq .
echo
curl -sS http://192.168.86.179:30185/ready | jq .
echo
curl -sS http://192.168.86.179:30185/metrics | head -n 20
echo
```

Chat (non-stream): `Authorization: Bearer` is required (stub accepts shape used below per upstream README).

```bash
curl -sS -X POST "http://192.168.86.179:30185/api/chat" \
  -H "Authorization: Bearer demo-token" \
  -H "Content-Type: application/json" \
  -H "X-Session-Id: sess_123" \
  -H "X-Request-Id: req_demo_001" \
  -H "X-Trace-Id: trace_demo_001" \
  -d '{
    "conversation_id": "conv_456",
    "message": "What is Taixing US visa status?",
    "metadata": {
      "page": "/support",
      "user_agent": "curl"
    }
  }' | jq .
echo
```

Chat (SSE): use `Accept: text/event-stream` or `?stream=true`.

```bash
curl -N -sS -X POST "http://192.168.86.179:30185/api/chat?stream=true" \
  -H "Authorization: Bearer demo-token" \
  -H "Content-Type: application/json" \
  -H "Accept: text/event-stream" \
  -H "X-Session-Id: sess_123" \
  -H "X-Request-Id: req_demo_002" \
  -H "X-Trace-Id: trace_demo_002" \
  -d '{
    "conversation_id": "conv_456",
    "message": "Stream a short answer",
    "metadata": { "page": "/support", "user_agent": "curl" }
  }'
```

## 4) Observability

After changing scrape rules, reload Prometheus:

```bash
sudo k3s kubectl apply -f manifests/observability/prometheus-grafana.yaml
sudo k3s kubectl rollout restart deployment/prometheus -n monitoring
```

Prometheus discovers Service `layer-gateway-api` in `ai-dev` with label `workload=gateway-api` (see `manifests/observability/prometheus-grafana.yaml`). Scrapes use `metrics_path: /metrics`.

NodePort:

- dev: `30185`
