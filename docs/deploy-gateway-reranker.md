# Deploy Reranker Gateway (dev)

Gateway image: [ghcr.io/taixingbi/layer-gateway-reranker-v1](https://github.com/taixingbi/layer-gateway-reranker-v1/pkgs/container/layer-gateway-reranker-v1) — source: [layer-gateway-reranker-v1](https://github.com/taixingbi/layer-gateway-reranker-v1)

Endpoints: `POST /v1/rerank`, `GET /health`, `GET /ready`, `GET /version`, `GET /metrics`, `GET /docs`. In-cluster: `http://layer-gateway-reranker:8000`; LAN: NodePort `30182` (`docs/port.md`), docs UI: `http://192.168.86.179:30182/docs`. vLLM backends (`:8002`): [deploy-vllm-reranker.md](deploy-vllm-reranker.md). Smoke tests: `docs/test-calls.md`. For Grafana dashboard `grafana-import/dashboard/reranker.json`, ensure `manifests/observability/prometheus-grafana.yaml` includes reranker static targets with label `workload=reranker` on `:8002`.

## 1) Configure backends (no `secretRef`)

The dev manifest does **not** use `envFrom.secretRef`. Backends and tuning are **environment variables** in `manifests/gateway-reranker/base/deployment.yaml`. The key variable for rerank traffic is **`RERANK_BACKENDS`** (`name=url,name=url`). Defaults use in-cluster DNS for vLLM rerank in the per-node bundle (`vllm-rerank-gpu-node-*.vllm.svc.cluster.local:8002`; see `manifests/vllm/vllm-bundle.yaml`).

```bash
# optional: confirm RERANK_BACKENDS on the live Deployment
sudo k3s kubectl -n ai-dev get deploy layer-gateway-reranker -o yaml | grep -A1 RERANK_BACKENDS
```

## 2) Deploy (Argo CD / GitOps)

Managed by `gateway-reranker-dev` via [app-of-apps](deploy-gitops-argocd.md).

```bash
sudo k3s kubectl get application gateway-reranker-dev -n argocd
sudo k3s kubectl get pods,svc -n ai-dev -l app=layer-gateway-reranker
sudo k3s kubectl get svc -A -o wide | grep 30182
sudo k3s kubectl get pods -n ai-dev -l app=layer-gateway-reranker -o wide
```

## 3) Version (`GET /version`)

Build metadata baked into the image at CI time; `environment` from `ENVIRONMENT` in the Deployment (`ai-dev`).

```bash
curl -sS http://192.168.86.179:30182/version | jq .
```

## 4) Example: `POST /v1/rerank`

From a host that can reach the dev NodePort (adjust IP if your server differs). `jq` is optional (drop `| jq .` if not installed). Include optional `conversation_id` in the JSON to tie the rerank call to a chat or session (omit if the gateway rejects unknown fields). Headers `X-Session-Id`, `X-Request-Id`, and `X-Trace-Id` are also used for tracing.

```bash
curl -sS -X POST http://192.168.86.179:30182/v1/rerank \
  -H "Content-Type: application/json" \
  -H "X-Request-Id: req-abc123" \
  -H "X-Session-Id: ses-xyz789" \
  -H "X-Trace-Id: trc-001" \
  -d '{
    "model": "BAAI/bge-reranker-v2-m3",
    "conversation_id": "conv_rerank_1",
    "query": "what is taixing visa",
    "documents": [
      "Taixing visa is the visa service product used by Taixing.",
      "This sentence is unrelated to the user question."
    ],
    "top_n": 2
  }' | jq .
echo
```

NodePorts:

- dev: `30182`

## Troubleshooting

Broken together with embed, Argo `manifests/ai`, or missing Grafana series? See **[fix-vllm-plane-cutover.md](fix-vllm-plane-cutover.md)**.

### `OutOfSync` + `/ready` shows backends `unhealthy`

`rollout restart` does **not** change `RERANK_BACKENDS`; it only recreates Pods with the **current** Deployment spec. After the `ai` → `vllm` move, sync GitOps first so backends use `*.vllm.svc.cluster.local`.

**Sync without `argocd` CLI** (from this repo on server-node-1):

```bash
cd ~/shared/huntai-platform/huntai-k3s
sudo k3s kubectl apply -k manifests/gateway-reranker/overlays/dev
sudo k3s kubectl -n ai-dev get deploy layer-gateway-reranker -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="RERANK_BACKENDS")].value}{"\n"}'
# expect: vllm-rerank-gpu-node-*.vllm.svc.cluster.local:8002
sudo k3s kubectl rollout restart deploy/layer-gateway-reranker -n ai-dev
curl -sS http://192.168.86.179:30182/ready | jq .
```

Or trigger Argo from the UI (Application `gateway-reranker-dev` → **Sync**). Argo should return **Synced** after apply.

### Gateway image has no `curl`

Use a one-off debug pod or Python inside the gateway container:

```bash
sudo k3s kubectl run -n ai-dev rerank-curl --rm -it --restart=Never \
  --image=curlimages/curl:8.5.0 -- \
  curl -sS http://vllm-rerank-gpu-node-1.vllm.svc.cluster.local:8002/health

sudo k3s kubectl -n ai-dev exec deploy/layer-gateway-reranker -- \
  python3 -c "import urllib.request; print(urllib.request.urlopen('http://vllm-rerank-gpu-node-1.vllm.svc.cluster.local:8002/health', timeout=2).read())"
```

### `curl: (7) Failed to connect` to NodePort `30182`

**On server-node-1**, curling the node’s own LAN IP (`192.168.86.179:30182`) can hang ~60s+ (NodePort hairpin / kube-proxy). That does **not** mean the gateway is down. Prefer ClusterIP or pod IP from the control plane:

```bash
IP=$(sudo k3s kubectl -n ai-dev get svc layer-gateway-reranker -o jsonpath='{.spec.clusterIP}')
curl -sS --max-time 5 "http://${IP}:8000/ready" | jq .
curl -sS --max-time 5 "http://${IP}:8000/health"
```

LAN smokes from another machine (laptop) to `192.168.86.179:30182` are fine. After rollout, wait until the new Pod is **`Running`** and endpoints list one IP before NodePort tests.

If ClusterIP also fails, check Pod and rollout:

```bash
sudo k3s kubectl -n ai-dev get pods,svc,endpoints -l app=layer-gateway-reranker
sudo k3s kubectl -n ai-dev logs deploy/layer-gateway-reranker --tail=50
sudo ss -tlnp | grep 30182
```
