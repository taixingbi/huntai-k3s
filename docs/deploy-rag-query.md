# Deploy RAG Query (dev)

Service image: [taixingbi/layer-rag-query-v1](https://hub.docker.com/r/taixingbi/layer-rag-query-v1) — source: [layer-rag-query-v1](https://github.com/taixingbi/layer-rag-query-v1)

HTTP API: `POST /v1/rag/query` (JSON body; see upstream README). MCP clients use `http://<host>:30183/mcp` when using FastMCP HTTP transport (NodePort; pod listens on `8000`). Required environment variables match upstream [`app/config.py`](https://github.com/taixingbi/layer-rag-query-v1/blob/main/app/config.py) and [`.env.example`](https://github.com/taixingbi/layer-rag-query-v1/blob/main/.env.example); the dev manifest uses LAN URLs on `192.168.86.179` for Qdrant, embedding gateway (`30181`), reranker gateway (`30182`), and inference gateway (`30180`). In-cluster callers may use Service DNS on port `8000` instead (e.g. `http://layer-gateway-embedding:8000`).

## Prerequisites

- Qdrant reachable at `QDRANT_URL` (manifest default: `http://192.168.86.179:6333` — adjust if yours differs).
- Embedding gateway, reranker gateway, and inference gateway reachable at the NodePorts on `192.168.86.179` used in the manifest (`30181`, `30182`, `30180`), or edit the YAML to use in-cluster Service DNS on port `8000` (`layer-gateway-embedding`, `layer-gateway-reranker`, `layer-gateway-inference`).
- Port map: `docs/port.md` (`30183` dev).

## 1) Configure env (no `secretRef` by default)

Edit `manifests/rag/layer-rag-query-dev.yaml` for non-default Qdrant host, keys (`QDRANT_API_KEY`, `EMBEDDING_INTERNAL_KEY`), or model names. For Grafana Cloud Loki from the app, add `GRAFANA_CLOUD_*` env vars per upstream `.env.example` (not set in this manifest by default).

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

## 3) Observability

After changing scrape rules, reload Prometheus:

```bash
sudo k3s kubectl apply -f manifests/observability/prometheus-grafana.yaml
sudo k3s kubectl rollout restart deployment/prometheus -n monitoring
```

Prometheus discovers Service `layer-rag-query` in `ai-dev` with label `workload=rag-query` (see `manifests/observability/prometheus-grafana.yaml`). Scrapes use `metrics_path: /metrics`; if the image does not expose that path yet, the target may show as down until the app exports Prometheus metrics.

## 4) Example: `POST /v1/rag/query`

From a host that can reach the dev NodePort (adjust IP if your server differs). `jq` is optional (drop `| jq .` if not installed).

```bash
curl -sS -X POST http://192.168.86.179:30183/v1/rag/query \
  -H "Content-Type: application/json" \
  -d '{
    "question": "what is taixing visa",
    "collection_base": "taixing_knowledge",
    "request_id": "req-abc123",
    "session_id": "ses-xyz789",
    "k": 5,
    "k_max": 40
  }' | jq .
echo
```

NodePorts:

- dev: `30183`
