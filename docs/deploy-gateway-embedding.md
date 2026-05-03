# Deploy Embedding Gateway (dev)

Gateway image: [taixingbi/layer-gateway-embed-v1](https://hub.docker.com/r/taixingbi/layer-gateway-embed-v1) — source: [layer-gateway-embed-v1](https://github.com/taixingbi/layer-gateway-embed-v1)

Endpoints: `POST /v1/embeddings`, `GET /health`, `GET /metrics`. In-cluster: `http://layer-gateway-embedding:8000`; LAN: NodePort `30181` (`docs/port.md`). Required headers on embed calls: `X-Request-Id`, `X-Trace-Id`, `X-Session-Id` (see upstream [README](https://github.com/taixingbi/layer-gateway-embed-v1#example)). Smoke tests: `docs/test-calls.md`. Prometheus scrapes Service `layer-gateway-embedding` as `workload=gateway-embedding` after `manifests/observability/prometheus-grafana.yaml`.

## 1) Configure backends (no `secretRef`)

The dev manifest does **not** use `envFrom.secretRef`. Backends and tuning are **environment variables** in `manifests/gateway/layer-gateway-embedding-dev.yaml` (same names as upstream [.env.example](https://github.com/taixingbi/layer-gateway-embed-v1/blob/main/.env.example)). The important variable is **`EMBED_BACKENDS`** (`name=url,name=url`). Defaults point at vLLM embed on the GPU nodes at `:8001`, consistent with `manifests/observability/prometheus-grafana.yaml` static targets. Edit the YAML or patch the Deployment if your LAN IPs or ports differ.

```bash
# optional: confirm EMBED_BACKENDS on the live Deployment
sudo k3s kubectl -n ai-dev get deploy layer-gateway-embedding -o yaml | grep -A1 EMBED_BACKENDS
```

## 2) Apply manifests

```bash
# dev
sudo k3s kubectl apply -f manifests/gateway/layer-gateway-embedding-dev.yaml
sudo k3s kubectl rollout restart deployment/layer-gateway-embedding -n ai-dev
sudo k3s kubectl get pods,svc -n ai-dev -l app=layer-gateway-embedding
sudo k3s kubectl get svc -A -o wide | grep 30181
sudo k3s kubectl get pods -n ai-dev -l app=layer-gateway-embedding -o wide
```

NodePorts:

- dev: `30181`
