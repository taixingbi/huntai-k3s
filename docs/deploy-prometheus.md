# Deploy Prometheus (Grafana Cloud metrics)

GitOps: Argo CD Application `observability` (includes Prometheus and Alloy). Bootstrap via [deploy-gitops-argocd.md](deploy-gitops-argocd.md).

```bash
sudo k3s kubectl get application observability -n argocd
sudo k3s kubectl get pods,svc -n monitoring -o wide
```

Set Grafana Cloud metrics token (`metrics:write`) safely:

```bash
read -s GRAFANA_CLOUD_API_KEY && echo
sudo k3s kubectl create secret generic prometheus-grafana-cloud-remote-write -n monitoring \
  --from-literal=api-key="$GRAFANA_CLOUD_API_KEY" \
  --dry-run=client -o yaml | sudo k3s kubectl apply -f -
unset GRAFANA_CLOUD_API_KEY
sudo k3s kubectl rollout restart deployment/prometheus -n monitoring
```

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
