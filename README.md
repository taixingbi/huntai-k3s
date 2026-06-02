# k3s server + GPU agents

Manifests and scripts for:

- `server-node-1` (`192.168.86.179`) as k3s control plane
- `gpu-node-1` (`192.168.86.173`) and `gpu-node-2` (`192.168.86.176`) as GPU workers

## Repository layout

| Path | Purpose |
|---|---|
| `argocd/applications/` | Argo CD Application manifests (GitOps bootstrap) |
| `manifests/gateway-api/` | Gateway API Kustomize base + dev overlay (GitOps source for `gateway-api-dev`) |
| `scripts/install-k3s-server.sh` | Install k3s server and print join token/url |
| `scripts/install-k3s-agent.sh` | Join an agent with `K3S_URL` + `K3S_TOKEN` |
| `scripts/install-nvidia-gpu-operator.sh` | Install GPU Operator for k3s containerd |
| `manifests/gpu/gpu-vectoradd-sample.yaml` | One-shot GPU smoke test (`nvidia-smi`) |
| `manifests/ai/inference-qwen25-7b.yaml` | vLLM inference workload + services (`ai`) |
| `manifests/gateway-inference/overlays/dev` | Chat gateway in `ai-dev` via Argo CD (`gateway-inference-dev`; ClusterIP `:8000`, NodePort `30180`) |
| `manifests/gateway-embedding/overlays/dev` | Embedding gateway in `ai-dev` via Argo CD (`gateway-embedding-dev`; NodePort `30181` → vLLM `:8001`) |
| `manifests/gateway-reranker/overlays/dev` | Reranker gateway in `ai-dev` via Argo CD (`gateway-reranker-dev`; NodePort `30182` → backend `:8002`) |
| `manifests/rag/overlays/dev` | RAG query in `ai-dev` via Argo CD (`rag-query-dev`; ClusterIP `:8000`, NodePort `30183`; [layer-rag-query-v1](https://github.com/taixingbi/layer-rag-query-v1)) |
| `manifests/orchestrator/` | Orchestrator in `ai-dev` (Argo CD `orchestrator-dev`; NodePort `30184`; [layer-orchestrator-v1](https://github.com/taixingbi/layer-orchestrator-v1)) |
| `manifests/gateway-api/overlays/dev` | Gateway API (FastAPI edge) in `ai-dev` via Argo CD (ClusterIP `:8000`, NodePort `30185`; [layer-gateway-api-v1](https://github.com/taixingbi/layer-gateway-api-v1)) |
| `manifests/web/overlays/dev` | Next.js web UI in `ai-dev` via Argo CD (`web-dev`; ClusterIP `:3000`, NodePort `30186`; public `https://dev.taixingai.com`) |
| `manifests/ingress/cloudflared-dev.yaml` | Cloudflare Tunnel in `ai-dev` → `dev.taixingai.com` (web), `argocd.taixingai.com` (Argo CD) ([docs/deploy-dev-cloudflare-tunnel.md](docs/deploy-dev-cloudflare-tunnel.md)) |
| `manifests/tool/` | GitHub MCP tool in `ai-dev` (Argo CD `mcp-github-dev`; NodePort `30191`; [layer-mcp-github-v1](https://github.com/taixingbi/layer-mcp-github-v1)) |
| `manifests/observability/prometheus-grafana.yaml` | Prometheus + Grafana Cloud remote_write |
| `manifests/observability/alloy-loki-cloud.yaml` | Alloy DaemonSet logs -> Grafana Cloud Loki |
| `grafana-import/dashboard/*.json` | Grafana dashboards (Prometheus + Loki) |
| `grafana-import/alert/prometheus-alert-rules.yaml` | Prometheus-format alert rules |
| `tmp.md` / `tmp/` | Local scratch (gitignored; never store real secrets) |

## Prerequisites

- sudo/root on hosts
- k3s agents can reach server on `6443`
- NVIDIA driver installed on GPU nodes (`nvidia-smi` works on host)

## 1) Install k3s server

On `server-node-1`:

```bash
cd ~/shared/k3s
sudo ./scripts/install-k3s-server.sh
```

If already installed, get token directly:

```bash
sudo cat /var/lib/rancher/k3s/server/node-token
```

## 2) Join GPU agents

On each GPU node:

```bash
cd ~/shared/k3s
export K3S_URL=https://192.168.86.179:6443
export K3S_TOKEN=<server-node-token>
sudo -E ./scripts/install-k3s-agent.sh
```

Verify on server:

```bash
sudo k3s kubectl get nodes -o wide
```

## 3) Install NVIDIA GPU Operator

On `server-node-1`:

```bash
cd ~/shared/k3s
sudo -E ./scripts/install-nvidia-gpu-operator.sh
```

Verify allocatable GPUs:

```bash
sudo k3s kubectl get nodes -o custom-columns='NAME:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu'
sudo k3s kubectl get pods -n gpu-operator -o wide | grep device-plugin
```

GPU smoke test:

```bash
sudo k3s kubectl apply -f manifests/gpu/gpu-vectoradd-sample.yaml
sudo k3s kubectl logs cuda-vectoradd
sudo k3s kubectl delete pod cuda-vectoradd
```

## 4) GitOps (Argo CD)

Install Argo CD, bootstrap Applications, and deploy the first app (`gateway-api-dev`) from Git:

- `docs/deploy-gitops-argocd.md`

## 5) Deploy workloads + observability

Detailed steps for vLLM, inference gateway (dev/prod), embedding gateway (dev), reranker gateway (dev), RAG query (dev), orchestrator (dev), Prometheus, Alloy, and Grafana import now live in:

- `docs/deploy-workloads-and-observability.md`

## 6) Test calls

All API smoke-test commands now live in:

- `docs/test-calls.md`

## 7) Quick troubleshooting

- `provided port is already allocated`: check existing Service NodePort with `kubectl get svc -A -o wide | grep <port>`
- Alloy crash with `mkdir /var/lib/alloy/data: permission denied`: apply latest `manifests/observability/alloy-loki-cloud.yaml`
- Loki push `401/403`: wrong `loki-username`/token or missing `logs:write`
- Prometheus no data in Grafana Cloud: confirm `prometheus-grafana-cloud-remote-write` secret and rollout restart
