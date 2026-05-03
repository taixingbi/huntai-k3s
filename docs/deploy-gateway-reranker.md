# Deploy Reranker Gateway (dev)

Gateway image: [taixingbi/layer-gateway-embed-v1](https://hub.docker.com/r/taixingbi/layer-gateway-embed-v1) — source: [layer-gateway-embed-v1](https://github.com/taixingbi/layer-gateway-embed-v1)

Endpoints: `POST /v1/rerank`, `GET /health`, `GET /metrics`. In-cluster: `http://layer-gateway-reranker:8000`; LAN: NodePort `30182` (`docs/port.md`). Smoke tests: `docs/test-calls.md`. For Grafana dashboard `grafana-import/dashboard/reranker.json`, ensure `manifests/observability/prometheus-grafana.yaml` includes reranker static targets with label `workload=reranker` on `:8002`.

## 1) Configure backends (no `secretRef`)

The dev manifest does **not** use `envFrom.secretRef`. Backends and tuning are **environment variables** in `manifests/gateway/layer-gateway-reranker-dev.yaml`. The key variable for rerank traffic is **`RERANK_BACKENDS`** (`name=url,name=url`) and defaults to GPU-node reranker backends on `:8002`.

```bash
# optional: confirm RERANK_BACKENDS on the live Deployment
sudo k3s kubectl -n ai-dev get deploy layer-gateway-reranker -o yaml | grep -A1 RERANK_BACKENDS
```

## 2) Apply manifests

```bash
# dev
sudo k3s kubectl apply -f manifests/gateway/layer-gateway-reranker-dev.yaml
sudo k3s kubectl rollout restart deployment/layer-gateway-reranker -n ai-dev
sudo k3s kubectl get pods,svc -n ai-dev -l app=layer-gateway-reranker
sudo k3s kubectl get svc -A -o wide | grep 30182
sudo k3s kubectl get pods -n ai-dev -l app=layer-gateway-reranker -o wide
```

NodePorts:

- dev: `30182`
