# Deploy Embedding Gateway (dev)

Gateway image: [ghcr.io/taixingbi/layer-gateway-embed-v1](https://github.com/taixingbi/layer-gateway-embed-v1/pkgs/container/layer-gateway-embed-v1) — source: [layer-gateway-embed-v1](https://github.com/taixingbi/layer-gateway-embed-v1)

Endpoints: `POST /v1/embeddings`, `GET /health`, `GET /ready`, `GET /version`, `GET /metrics`. In-cluster: `http://layer-gateway-embedding:8000`; LAN: NodePort `30181` (`docs/port.md`). Required headers on embed calls: `X-Request-Id`, `X-Trace-Id`, `X-Session-Id` (see upstream [README](https://github.com/taixingbi/layer-gateway-embed-v1#example)). vLLM backends (`:8001`): [deploy-vllm-embedding.md](deploy-vllm-embedding.md). Smoke tests: `docs/test-calls.md`. Prometheus scrapes Service `layer-gateway-embedding` as `workload=gateway-embedding` after `manifests/observability/prometheus-configmap.yaml`.

Broken together with rerank, Argo `manifests/ai`, or missing Grafana series? See **[fix-vllm-plane-cutover.md](fix-vllm-plane-cutover.md)**.

## 1) Configure backends and routing (ConfigMap)

The dev manifest uses a **ConfigMap** mounted at `/app/config.yaml` (same pattern as [gateway-inference](deploy-gateway-inference.md)). Backends, per-node `soft_limit`/`hard_limit`, routing weights, and admission limits live in `manifests/gateway-embedding/base/configmap.yaml`. Defaults use in-cluster DNS for vLLM embed in the per-node bundle (`vllm-embed-gpu-node-*.vllm.svc.cluster.local:8001`; see `manifests/vllm/vllm-bundle.yaml`). Edit the GitOps manifest and push to `main`.

```bash
# confirm mounted config on the live pod
sudo k3s kubectl -n ai-dev exec deploy/layer-gateway-embedding -- cat /app/config.yaml
```

## 2) Deploy (Argo CD / GitOps)

Managed by `gateway-embedding-dev` via [app-of-apps](deploy-gitops-argocd.md).

```bash
sudo k3s kubectl get application gateway-embedding-dev -n argocd
sudo k3s kubectl get pods,svc -n ai-dev -l app=layer-gateway-embedding
sudo k3s kubectl get svc -A -o wide | grep 30181
sudo k3s kubectl get pods -n ai-dev -l app=layer-gateway-embedding -o wide
```

## 3) Readiness (`GET /ready`)

Probes each vLLM embedding backend in the ConfigMap (`GET {url}/health`). Kubernetes readiness uses `/ready`; liveness stays on `/health`.

```bash
curl -sS http://192.168.86.179:30181/ready | jq .
```

Expected when both GPU nodes are up:

```json
{
  "status": "ready",
  "healthy_backends": 2,
  "total_backends": 2,
  "backends": {
    "embed-node-1": "healthy",
    "embed-node-2": "healthy"
  }
}
```

## 4) Version (`GET /version`)

Build metadata baked into the image at CI time; `environment` from `ENVIRONMENT` in the Deployment (`ai-dev`).

```bash
curl -sS http://192.168.86.179:30181/version | jq .
```

## 5) Example: `POST /v1/embeddings`

From a host that can reach NodePort `30181`. The body requires `model` and `input`. Add optional `conversation_id` to tie the call to a chat or session (omit if the gateway rejects unknown fields). Headers `X-Session-Id`, `X-Request-Id`, and `X-Trace-Id` are required for tracing.

```bash
curl -sS http://192.168.86.179:30181/v1/embeddings \
  -H "X-Request-Id: request_id_1" \
  -H "X-Trace-Id: trace_id_1" \
  -H "X-Session-Id: session_id_1" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "BAAI/bge-m3",
    "conversation_id": "conv_embed_1",
    "input": "hello world"
  }' | jq .
echo
```

NodePorts:

- dev: `30181`
