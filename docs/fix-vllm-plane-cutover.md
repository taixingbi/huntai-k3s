# Fix vLLM plane after `ai` → `vllm` migration

Use this runbook when **embed**, **rerank**, and **inference** all break together:

- Argo `vllm-inference`: `manifests/ai: app path does not exist`
- Gateways: `/ready` shows backends **unhealthy**, `Backends unavailable` on `/v1/rerank` or `/v1/embeddings`
- Grafana/Prometheus: `histogram_quantile(...{job="vllm-inference"}...)` (or `workload="embedding"` / `workload="reranker"`) returns **no data**
- Bundles still in namespace **`ai`** while gateways and Prometheus expect **`vllm`**

Application tier stays in **`ai-dev`**. Only the GPU vLLM bundle moves to **`vllm`**.

Run on **server-node-1** from `~/shared/huntai-platform/huntai-k3s` unless noted.

---

## Step 0 — Confirm the mismatch

```bash
sudo k3s kubectl get ns | grep -E '^(vllm|ai)\s'
sudo k3s kubectl get pods -A | grep vllm-bundle
sudo k3s kubectl get application vllm-inference -n argocd

sudo k3s kubectl -n ai-dev get deploy layer-gateway-embedding \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="EMBED_BACKENDS")].value}{"\n"}'
sudo k3s kubectl -n ai-dev get deploy layer-gateway-reranker \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="RERANK_BACKENDS")].value}{"\n"}'
```

| Symptom | Meaning |
|--------|---------|
| No namespace `vllm`, pods in `ai` | Inference plane not migrated |
| Argo error `manifests/ai` | Cluster Application CR is stale |
| Gateways use `*.vllm.svc` | Correct Git; useless until `vllm` exists |
| `up{workload="inference"} == 0` | Prometheus not scraping (wrong namespace) |

---

## Step 1 — Update Git and fix Argo `vllm-inference`

```bash
cd ~/shared/huntai-platform/huntai-k3s
git pull
```

Re-register the Application (path `manifests/vllm`, destination namespace `vllm`):

```bash
sudo k3s kubectl apply -f argocd/applications/vllm-inference.yaml
```

In Argo CD UI: **vllm-inference** → **Refresh** (hard) → **Sync**.

Or trigger sync without `argocd` CLI:

```bash
sudo k3s kubectl patch application vllm-inference -n argocd --type merge \
  -p '{"operation":{"initiatedBy":{"username":"tb"},"sync":{"prune":true}}}'
```

**Pass:**

```bash
sudo k3s kubectl get application vllm-inference -n argocd
# SYNC STATUS: Synced   HEALTH STATUS: Healthy (may take 15–45+ min while models load)

sudo k3s kubectl get ns vllm
sudo k3s kubectl -n vllm get pods,svc -l app=vllm-bundle -o wide
```

Both `vllm-bundle-gpu-node-*` pods must reach **`1/1 Running`** and Ready (startupProbe can take a long time).

If sync still fails, apply manifests directly:

```bash
sudo k3s kubectl apply -k manifests/vllm
```

---

## Step 2 — Remove duplicate bundles in `ai`

After **`vllm`** pods are healthy, delete the stray copy in **`ai`** (frees GPUs and avoids confusion):

```bash
sudo k3s kubectl -n vllm get pods -l app=vllm-bundle
# both 1/1 Running, then:

sudo k3s kubectl delete deploy -n ai vllm-bundle-gpu-node-1 vllm-bundle-gpu-node-2 2>/dev/null || true
# If namespace ai has nothing else you need:
sudo k3s kubectl get all -n ai
sudo k3s kubectl delete namespace ai
```

---

## Step 3 — Sync embed and rerank **gateways** (`ai-dev`)

Git already points backends at `*.vllm.svc.cluster.local`. Apply and restart:

```bash
sudo k3s kubectl apply -k manifests/gateway-embedding/overlays/dev
sudo k3s kubectl apply -k manifests/gateway-reranker/overlays/dev

sudo k3s kubectl -n ai-dev get deploy layer-gateway-embedding \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="EMBED_BACKENDS")].value}{"\n"}'
sudo k3s kubectl -n ai-dev get deploy layer-gateway-reranker \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="RERANK_BACKENDS")].value}{"\n"}'
# Must contain .vllm.svc.cluster.local (not .ai.svc)

sudo k3s kubectl rollout restart deploy/layer-gateway-embedding deploy/layer-gateway-reranker -n ai-dev
sudo k3s kubectl rollout status deploy/layer-gateway-embedding -n ai-dev
sudo k3s kubectl rollout status deploy/layer-gateway-reranker -n ai-dev
```

**Pass** (from control plane, use ClusterIP — NodePort to `192.168.86.179` can hang from the same node):

```bash
EIP=$(sudo k3s kubectl -n ai-dev get svc layer-gateway-embedding -o jsonpath='{.spec.clusterIP}')
RIP=$(sudo k3s kubectl -n ai-dev get svc layer-gateway-reranker -o jsonpath='{.spec.clusterIP}')

curl -sS --max-time 10 "http://${EIP}:8000/ready" | jq .
curl -sS --max-time 10 "http://${RIP}:8000/ready" | jq .
```

Each should show **`status": "ready"`** and **2/2 backends healthy**.

Smoke (full JSON bodies in [deploy-gateway-embedding.md](deploy-gateway-embedding.md) and [deploy-gateway-reranker.md](deploy-gateway-reranker.md)).

---

## Step 4 — Sync **Prometheus** scrape config (metrics for all three workloads)

Prometheus only discovers vLLM targets in namespace **`vllm`**:

| `job` | `workload` label | Service(s) |
|-------|------------------|------------|
| `vllm-inference` | `inference` | `vllm-inference` (:8000 chat) |
| `vllm-embedding` | `embedding` | `vllm-embed-gpu-node-*` (:8001) |
| `vllm-reranker` | `reranker` | `vllm-rerank-gpu-node-*` (:8002) |

```bash
sudo k3s kubectl apply -k manifests/observability/
sudo k3s kubectl -n monitoring rollout restart deploy/prometheus 2>/dev/null || \
  sudo k3s kubectl -n monitoring rollout restart statefulset/prometheus 2>/dev/null || true
```

Sync Argo app if you use it: **observability** → Sync.

**Pass** (Prometheus UI → Status → Targets, or from a host with port-forward):

```bash
# Expect 2 targets UP per job when both GPU nodes are ready
# up{workload="inference"} == 1  (2 series)
# up{workload="embedding"} == 1   (2 series)
# up{workload="reranker"} == 1    (2 series)
```

Generate a little traffic (embed/rerank/chat smokes) so `rate(...[5m])` is non-empty.

---

## Step 5 — Grafana / PromQL (inference, embed, rerank)

Prefer **`workload`** (repo dashboards), not only **`job`**. Use **`node`** for per-GPU lines (set by Prometheus relabel on all three vLLM jobs).

**Inference (chat p99 e2e):**

```promql
histogram_quantile(
  0.99,
  sum(rate(vllm:e2e_request_latency_seconds_bucket{workload="inference"}[5m])) by (le, node)
)
```

**Embedding:**

```promql
histogram_quantile(
  0.99,
  sum(rate(vllm:e2e_request_latency_seconds_bucket{workload="embedding"}[5m])) by (le, node)
)
```

**Reranker:**

```promql
histogram_quantile(
  0.99,
  sum(rate(vllm:e2e_request_latency_seconds_bucket{workload="reranker"}[5m])) by (le, node)
)
```

Debug when empty:

```promql
up{workload=~"inference|embedding|reranker"}
count by (workload) (vllm:e2e_request_latency_seconds_bucket)
```

`job="vllm-inference"` still works **if** targets are UP; `workload=` is what alerts and imported dashboards use.

---

## Step 6 — Optional Argo hygiene

```bash
sudo k3s kubectl apply -f argocd/app-of-apps.yaml   # once, if needed
sudo k3s kubectl get applications -n argocd | grep -E 'vllm|gateway|observability'
```

Ensure **gateway-embedding-dev**, **gateway-reranker-dev**, **vllm-inference**, **observability** are **Synced**.

---

## Quick reference — what broke vs fix

| Component | Expected | Typical break | Fix step |
|-----------|----------|---------------|----------|
| vLLM bundles | `vllm` namespace | Stuck in `ai`, Argo `manifests/ai` | 1–2 |
| Embed gateway | `*.vllm.svc:8001` | `.ai.svc` or no `vllm` | 1, 3 |
| Rerank gateway | `*.vllm.svc:8002` | same | 1, 3 |
| Inference gateway | NodePort `30080` on GPU LAN IPs | Usually OK (configmap) | — |
| Prometheus | scrape `vllm` ns | still scraping `ai` / no targets | 4 |
| Grafana p99 | `workload=` + `node` | no targets / no traffic | 4–5 |

---

## Related docs

- [deploy-vllm-inference.md](deploy-vllm-inference.md) — bundle rollout
- [deploy-vllm-embedding.md](deploy-vllm-embedding.md) — `:8001` smokes
- [deploy-vllm-reranker.md](deploy-vllm-reranker.md) — `:8002` smokes
- [deploy-gateway-embedding.md](deploy-gateway-embedding.md) — gateway troubleshooting
- [deploy-gateway-reranker.md](deploy-gateway-reranker.md) — gateway troubleshooting
- [deploy-prometheus.md](deploy-prometheus.md) — observability stack
