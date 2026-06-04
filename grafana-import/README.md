# Grafana dashboards and Prometheus alert rules (import into Grafana Cloud)

Upstream: [layer-observability-grafana](https://github.com/taixingbi/layer-observability-grafana). **Fork versions:** [VERSIONS.md](VERSIONS.md).

| Path | Upstream |
|------|----------|
| `dashboard/inference.json` | [inference.json](https://github.com/taixingbi/layer-observability-grafana/blob/main/dashboards/inference.json) — **huntai fork** (base/sft/dpo) |
| `dashboard/embedding.json` | [embedding.json](https://github.com/taixingbi/layer-observability-grafana/blob/main/dashboards/embedding.json) |
| `dashboard/gpu.json` | [gpu.json](https://github.com/taixingbi/layer-observability-grafana/blob/main/dashboards/gpu.json) |
| `dashboard/reranker.json` | huntai-only |
| `dashboard/loki-logs-http.json` | huntai-only (Alloy → Loki) |
| `alert/prometheus-alert-rules.yaml` | [prometheus-alert-rules.yaml](https://github.com/taixingbi/layer-observability-grafana/blob/main/alert/prometheus-alert-rules.yaml) |
| `alert/loki-gateway-log-level-alerts.yaml` | huntai-only |

## Sync from upstream

```bash
./scripts/sync-grafana-dashboards.sh              # download to dashboard/.upstream/
./scripts/sync-grafana-dashboards.sh --diff       # compare
./scripts/sync-grafana-dashboards.sh --print-versions
./scripts/sync-grafana-dashboards.sh --apply-safe # overwrite embedding.json + gpu.json only
```

**Never** `--apply-safe` for `inference.json` — merge panel changes manually after `--diff`.

## Import into Grafana Cloud

1. **Dashboards** → **New** → **Import** → upload JSON from `dashboard/`.
2. Check **`version`** and **`description`** in the file (or `huntai-k3s:N` tag) before import — re-import when version bumps.
3. Map **Prometheus** / **Loki** datasource UID (same as Explore).

## Alert rules

**Prometheus** (`alert/prometheus-alert-rules.yaml`): **Alerting** → **Alert rules** → **Import** → Prometheus YAML. Rules may use `service=` labels; scrape config here uses `workload=` — edit if needed ([deploy-prometheus.md](../docs/deploy-prometheus.md)).

**Loki** (`alert/loki-gateway-log-level-alerts.yaml`): create Grafana-managed rules from LogQL in that file.

## Architecture

Metrics labels and gateway → vLLM paths: [docs/architecture.md](../docs/architecture.md).
