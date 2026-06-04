# Deploy Prometheus (Grafana Cloud metrics)

GitOps: Argo CD Application `observability` (includes Prometheus and Alloy). Bootstrap via [deploy-gitops-argocd.md](deploy-gitops-argocd.md).

```bash
sudo k3s kubectl get application observability -n argocd
sudo k3s kubectl get pods,svc -n monitoring -o wide
```

Create the remote_write Secret **before** Argo syncs `observability` (Secret is not in Git). Set Grafana Cloud metrics token (`metrics:write`) safely:

```bash
read -s GRAFANA_CLOUD_API_KEY && echo
sudo k3s kubectl create secret generic prometheus-grafana-cloud-remote-write -n monitoring \
  --from-literal=api-key="$GRAFANA_CLOUD_API_KEY" \
  --dry-run=client -o yaml | sudo k3s kubectl apply -f -
unset GRAFANA_CLOUD_API_KEY
sudo k3s kubectl rollout restart deployment/prometheus -n monitoring
```

Remote write uses **basic auth**: `username` = Grafana Cloud Prometheus **instance ID** (`3067716` in [`prometheus-grafana.yaml`](../manifests/observability/prometheus-grafana.yaml)), `password` = a **`metrics:write`** access policy token (not Loki `logs:write`, not a stale placeholder).

### Grafana Cloud empty but local `9091` works (`401 invalid token`)

Symptom in Prometheus logs:

```text
remote_write ... 401 Unauthorized ... authentication error: invalid token
```

Local Prometheus (`http://192.168.86.179:9091`) has series; **Grafana Cloud Explore** stays empty — this is **not** a PromQL bug.

**Fix:**

1. In [Grafana Cloud](https://grafana.com/) → your stack → **Connections** / **Add new connection** → **Prometheus** → create or rotate a token with **`metrics:write`** (or use an existing valid metrics token).
2. Confirm the **Instance ID** matches `basic_auth.username` in `prometheus-config` (currently `3067716`). If your stack ID changed, update the ConfigMap and restart Prometheus.
3. Update the cluster secret (no echo in shell history):

```bash
read -s GRAFANA_CLOUD_METRICS_TOKEN && echo
sudo k3s kubectl create secret generic prometheus-grafana-cloud-remote-write -n monitoring \
  --from-literal=api-key="$GRAFANA_CLOUD_METRICS_TOKEN" \
  --dry-run=client -o yaml | sudo k3s kubectl apply -f -
unset GRAFANA_CLOUD_METRICS_TOKEN
sudo k3s kubectl rollout restart deployment/prometheus -n monitoring
```

4. **Pass** — errors stop:

```bash
sudo k3s kubectl -n monitoring logs deploy/prometheus --tail=30 | grep -i remote_write
# No new 401 lines after ~2 minutes
```

5. In **Grafana Cloud Explore** (hosted Prometheus datasource), after ~2–5 minutes:

```promql
up{cluster="k3s", job=~"vllm-.*"}
histogram_quantile(0.99, sum(rate(vllm:e2e_request_latency_seconds_bucket{cluster="k3s", workload="inference"}[5m])) by (le, node))
```

**Argo CD:** The metrics Secret is **not** in Git ([secrets/README.md](../secrets/README.md)). If you still see 401 after rotating, confirm Argo did not revert the Secret — `kubectl get secret prometheus-grafana-cloud-remote-write -n monitoring -o jsonpath='{.data.api-key}' | wc -c` should be non-zero and must not match a placeholder string.

**Workaround until token is fixed:** point Grafana at in-cluster Prometheus (`9091`) as a separate datasource, or keep using the local Prometheus UI for queries.

## GPU telemetry (DCGM)

GPU hardware metrics come from **NVIDIA GPU Operator DCGM exporter** in namespace **`gpu-operator`** (port **9400**), **not** from a standalone Docker `dcgm-exporter` on GPU nodes.

Prometheus job **`dcgm-exporter`** in [`manifests/observability/prometheus-grafana.yaml`](../manifests/observability/prometheus-grafana.yaml) discovers Services matching `.*dcgm-exporter` and labels targets `workload=gpu-telemetry`. Grafana dashboard **`layer-gpu-dcgm`** (`grafana-import/dashboard/gpu.json`) and alert rules depend on these series.

**Install / enable DCGM** (uses host NVIDIA driver; `driver.enabled=false`):

```bash
cd ~/shared/huntai-platform/huntai-k3s
sudo -E ./scripts/install-nvidia-gpu-operator.sh
```

Helm sets **`dcgmExporter.enabled=true`**. Expect a DCGM DaemonSet pod **Running** on **`gpu-node-1`** and **`gpu-node-2`**.

**Verify before removing Docker DCGM on GPU nodes:**

```bash
sudo ./scripts/migrate-docker-dcgm-to-k3s.sh verify
```

**Pass:** DCGM pods on both GPU nodes; Prometheus reports at least one **up** `dcgm-exporter` target per node.

Optional Prometheus UI (from server-node-1):

```bash
sudo k3s kubectl port-forward -n monitoring svc/prometheus 9090:9090
# http://127.0.0.1:9090/targets → job dcgm-exporter
```

Example query:

```promql
DCGM_FI_DEV_GPU_UTIL{workload="gpu-telemetry"}
```

## vLLM scrape targets (inference, embedding, reranker)

Three **separate** Prometheus jobs scrape three **ports** on the bundle pods (namespace **`vllm`**):

| Job | `workload` | Scrapes | Per-GPU label |
|-----|------------|---------|----------------|
| `vllm-inference` | `inference` | Service `vllm-inference` → `:8000` (chat) | `node` from pod label `vllm-node` |
| `vllm-embedding` | `embedding` | Services `vllm-embed-gpu-node-*` → `:8001` | `node` = `gpu-node-1`, `gpu-node-2`, … |
| `vllm-reranker` | `reranker` | Services `vllm-rerank-gpu-node-*` → `:8002` | `node` = `gpu-node-1`, `gpu-node-2`, … |

All jobs also set `kubernetes_node` (hostname) and `cluster="k3s"` (external label from remote_write).

### Check targets on server-node-1

```bash
sudo k3s kubectl port-forward -n monitoring svc/prometheus 9090:9090 &
# Browser: http://127.0.0.1:9090/targets — filter jobs vllm-inference, vllm-embedding, vllm-reranker
# Expect: 2 targets UP per job (one per GPU node)

curl -sG 'http://127.0.0.1:9090/api/v1/targets' | jq -r '
  .data.activeTargets[]
  | select(.labels.job | test("^vllm-"))
  | "\(.labels.job)\t\(.health)\t\(.labels.workload // "-")\t\(.scrapeUrl)"'
```

In **Grafana Cloud Explore** (after remote_write), use the same PromQL as below.

### PromQL: targets up?

```promql
up{job=~"vllm-.*"}
```

Expect **6** series total (3 jobs × 2 GPU nodes). Each job should show **2/2 UP** in Targets, not **6/6** (extra addresses per pod are dropped with `target_kind=Pod` relabel).

### Duplicate Grafana legend lines

**A) Chat inference — three lines per GPU (base / sft / dpo)**  
The bundle chat process loads **base Qwen** plus **two LoRA adapters** (`router-qwen2.5-7b-sft-v1.00`, `router-qwen2.5-7b-dpo-v1.00`). vLLM tags metrics with **`model_name`**, so you often get **3 series per node**, not 3 GPUs. Legends that only show `{{node}}` look like repeated `gpu-node-1` entries.

Confirm in Explore:

```promql
count by (node, model_name) (vllm:num_requests_running{workload="inference"})
```

Expected model names (approx.): `Qwen/Qwen2.5-7B-Instruct`, `router-qwen2.5-7b-sft-v1.00`, `router-qwen2.5-7b-dpo-v1.00`.

**Operational “2 lines per GPU”** (roll up adapters): `sum by (node) (vllm:num_requests_running{workload="inference"})`.

**Router breakdown “6 lines”** with clear names: re-import `grafana-import/dashboard/inference.json` (v3) — legends use `{{node}} {{variant}}` with `base` / `sft` / `dpo` from `model_name`.

**B) Still 3× the same `model_name`**  
Duplicate **scrape targets** (pod + node + hostname addresses). **Fix:** apply `prometheus-grafana.yaml` (Pod-only targets); targets should show **2/2 UP** per `vllm-*` job. Re-import `embedding.json` / `reranker.json` (single model per port — should be **2 lines** only).

### PromQL: discover labels (before histogram)

```promql
count by (job, workload, node) ({__name__=~"vllm:.*"})
```

```promql
rate(vllm:request_success_total{workload="embedding"}[5m])
rate(vllm:request_success_total{workload="reranker"}[5m])
rate(vllm:request_success_total{workload="inference"}[5m])
```

If these return data but `e2e_request_latency_seconds_bucket` does not, the histogram metric may have no observations yet — run more gateway or direct vLLM traffic.

### Common query mistakes

| Mistake | Why it fails |
|---------|----------------|
| `job="vllm-inference"` on **embed/rerank** panels | Chat job only scrapes `:8000`; embed/rerank metrics use `job="vllm-embedding"` / `job="vllm-reranker"` |
| Only `job=` filter, ignore `workload=` | Repo dashboards/alerts use **`workload="inference"`** etc. (more stable) |
| `by (le, kubernetes_node)` while legend expects `node` | Works for inference if `kubernetes_node` exists; imported dashboards use **`by (le, node)`** |
| `histogram_quantile` right after one smoke | `rate(...[5m])` needs counter increases over the range window |
| Query local Prometheus but view Grafana Cloud | Metrics flow via **remote_write**; query the **Grafana Cloud** Prometheus datasource, not a stale local UID |

### Correct p99 e2e latency (matches imported dashboards)

```promql
histogram_quantile(0.99, sum(rate(vllm:e2e_request_latency_seconds_bucket{workload="inference"}[5m])) by (le, node))
histogram_quantile(0.99, sum(rate(vllm:e2e_request_latency_seconds_bucket{workload="embedding"}[5m])) by (le, node))
histogram_quantile(0.99, sum(rate(vllm:e2e_request_latency_seconds_bucket{workload="reranker"}[5m])) by (le, node))
```

Equivalent with `job` (narrower):

```promql
histogram_quantile(0.99, sum(rate(vllm:e2e_request_latency_seconds_bucket{job="vllm-inference"}[5m])) by (le, node))
```

Use **`workload=`** for all three; use **`job=`** only when you mean one scrape job.

If targets are UP and `request_success_total` has data but histograms stay empty, widen the range to **`[15m]`** or generate sustained traffic, then retry.

**Decommission host Docker `dcgm-exporter`** (after verify passes):

```bash
# SSH to each GPU node, or:
export GPU_NODE_SSH_USER=tb
export GPU_NODE_SSH_HOSTS=192.168.86.173,192.168.86.176
sudo -E ./scripts/migrate-docker-dcgm-to-k3s.sh decommission
```

On each GPU node manually:

```bash
sudo docker stop dcgm-exporter
sudo docker rm dcgm-exporter
```

Do **not** run Docker and GPU Operator DCGM long term — Prometheus only scrapes the in-cluster exporter.

**Rollback:** restart Docker dcgm temporarily only if k3s DCGM is broken; then fix GPU Operator and remove Docker again (see script header in [`scripts/migrate-docker-dcgm-to-k3s.sh`](../scripts/migrate-docker-dcgm-to-k3s.sh)).
