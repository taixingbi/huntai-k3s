# Grafana dashboard versions (huntai-k3s)

Bump **`version`** in the JSON when panel queries or legends change. After editing, re-import in Grafana Cloud (or bump UID folder). Run `scripts/sync-grafana-dashboards.sh` to refresh upstream snapshots.

| File | `version` | `uid` | Upstream | huntai-k3s notes |
|------|-----------|-------|----------|------------------|
| `dashboard/inference.json` | **3** | `layer-vllm-inference` | [inference.json](https://github.com/taixingbi/layer-observability-grafana/blob/main/dashboards/inference.json) | **Fork:** `{{node}} {{variant}}` (base/sft/dpo) via `model_name` |
| `dashboard/embedding.json` | **2** | `layer-vllm-embedding` | [embedding.json](https://github.com/taixingbi/layer-observability-grafana/blob/main/dashboards/embedding.json) | `sum by (node)` / `max by (node)` |
| `dashboard/reranker.json` | **2** | `layer-vllm-reranker` | — | huntai-only; no upstream file |
| `dashboard/gpu.json` | **1** | `layer-gpu-dcgm` | [gpu.json](https://github.com/taixingbi/layer-observability-grafana/blob/main/dashboards/gpu.json) | DCGM `workload=gpu-telemetry` |
| `dashboard/loki-logs-http.json` | **1** | `layer-loki-http-logs` | — | huntai-only (Alloy → Loki) |

Tag convention: `huntai-k3s:N` in dashboard `tags` matches fork `version` where applicable.
