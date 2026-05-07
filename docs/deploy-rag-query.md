# Deploy RAG Query (dev)

Service image: [taixingbi/layer-rag-query-v1](https://hub.docker.com/r/taixingbi/layer-rag-query-v1) — source: [layer-rag-query-v1](https://github.com/taixingbi/layer-rag-query-v1)

HTTP API: `POST /v1/rag/query` (JSON body; see upstream README). MCP clients use `http://<host>:30183/mcp` when using FastMCP HTTP transport (NodePort; pod listens on `8000`). Environment variables follow upstream [`app/config.py`](https://github.com/taixingbi/layer-rag-query-v1/blob/main/app/config.py) and [`.env.example`](https://github.com/taixingbi/layer-rag-query-v1/blob/main/.env.example). The dev manifest uses LAN `192.168.86.179` for Qdrant, embedding gateway (`30181`), reranker gateway (`30182`), and **vLLM inference** (`30080`). To use the inference **gateway** instead, set `INFERENCE_URL` to `http://192.168.86.179:30180` (or `http://layer-gateway-inference:8000` in-cluster). In-cluster callers may use Service DNS on port `8000` for gateways (e.g. `http://layer-gateway-embedding:8000`).

## Prerequisites

- Qdrant reachable at `QDRANT_URL` (manifest default: `http://192.168.86.179:6333` — adjust if yours differs).
- Embedding gateway and reranker gateway reachable at NodePorts `30181` and `30182`; vLLM inference at `30080` (manifest default). Override `INFERENCE_URL` for gateway (`30180`) or in-cluster DNS (`layer-gateway-inference:8000`, `vllm-inference.ai.svc.cluster.local:8000`) as needed.
- Port map: `docs/port.md` (`30183` dev).

## 1) Configure env (no `secretRef` by default)

Edit `manifests/rag/layer-rag-query-dev.yaml` for non-default Qdrant host, `QDRANT_API_KEY`, or model names. For Grafana Cloud Loki from the app, add `GRAFANA_CLOUD_*` env vars per upstream `.env.example` (not set in this manifest by default).

## 2) Apply manifests

```bash
# optional: preload image on the node
sudo k3s ctr images pull docker.io/taixingbi/layer-rag-query-v1:latest

sudo k3s kubectl apply -f manifests/rag/layer-rag-query-dev.yaml
sudo k3s kubectl rollout restart deployment/layer-rag-query -n ai-dev
sudo k3s kubectl get pods,svc -n ai-dev -l app=layer-rag-query
sudo k3s kubectl get svc -A -o wide | grep 30183
sudo k3s kubectl get pods -n ai-dev -l app=layer-rag-query -o wide
```

## 3) Quick checks: health and ready

From a host that can reach NodePort `30183`:

```bash
curl -iS http://192.168.86.179:30183/health
echo
curl -iS http://192.168.86.179:30183/ready
echo
```

## 4) Observability

After changing scrape rules, reload Prometheus:

```bash
sudo k3s kubectl apply -f manifests/observability/prometheus-grafana.yaml
sudo k3s kubectl rollout restart deployment/prometheus -n monitoring
```

Prometheus discovers Service `layer-rag-query` in `ai-dev` with label `workload=rag-query` (see `manifests/observability/prometheus-grafana.yaml`). Scrapes use `metrics_path: /metrics`; if the image does not expose that path yet, the target may show as down until the app exports Prometheus metrics.

## 5) Example: `POST /v1/rag/query`

From a host that can reach the dev NodePort (adjust IP if your server differs). `jq` is optional (drop `| jq .` if not installed).

```bash
curl -sS -X POST http://192.168.86.179:30183/v1/rag/query \
  -H "Content-Type: application/json" \
  -H "X-Request-Id: req-abc123" \
  -H "X-Session-Id: ses-xyz789" \
  -H "X-Trace-Id: trc-001" \
  -d '{
    "question": "what is taixing visa",
    "collection_base": "taixing_knowledge",
    "k": 5,
    "k_max": 40
  }' | jq .
echo
```

NodePorts:

- dev: `30183`
