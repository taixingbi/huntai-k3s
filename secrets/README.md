# Grafana Cloud secrets (manual bootstrap)

These Secrets are **not** in `manifests/observability/` so Argo CD **cannot** overwrite rotated tokens with Git placeholders.

Create them **before** the `observability` Application syncs (or immediately after first cluster install). See [docs/cluster-secrets.md](../docs/cluster-secrets.md).

## Prometheus remote_write

Token: Grafana Cloud access policy with **`metrics:write`** (`glc_...`).  
Username for remote_write is in ConfigMap `prometheus-config` (`basic_auth.username`, currently `3067716`).

```bash
read -s GRAFANA_CLOUD_METRICS_TOKEN && echo
sudo k3s kubectl create secret generic prometheus-grafana-cloud-remote-write -n monitoring \
  --from-literal=api-key="$GRAFANA_CLOUD_METRICS_TOKEN" \
  --dry-run=client -o yaml | sudo k3s kubectl apply -f -
unset GRAFANA_CLOUD_METRICS_TOKEN
sudo k3s kubectl rollout restart deployment/prometheus -n monitoring
```

Details: [docs/deploy-prometheus.md](../docs/deploy-prometheus.md)

## Alloy → Loki

Token: **`logs:write`**. Keys: `loki-url`, `loki-username`, `api-key`.

```bash
sudo k3s kubectl create secret generic alloy-grafana-cloud-loki -n monitoring \
  --from-literal=loki-url='https://logs-prod-XXX.grafana.net/loki/api/v1/push' \
  --from-literal=loki-username='YOUR_LOKI_USER_ID' \
  --from-literal=api-key='glc_YOUR_TOKEN' \
  --dry-run=client -o yaml | sudo k3s kubectl apply -f -
sudo k3s kubectl rollout restart daemonset/alloy-logs -n monitoring
```

Details: [docs/deploy-alloy-loki.md](../docs/deploy-alloy-loki.md)

## Local templates (optional)

Copy an example, fill values locally, apply once — **never commit real tokens**:

```bash
cp secrets/examples/prometheus-grafana-cloud-remote-write.secret.example.yaml \
  prometheus-grafana-cloud-secret.local.yaml   # gitignored
# edit, then: sudo k3s kubectl apply -f prometheus-grafana-cloud-secret.local.yaml
```

## Upgrading from Git-managed placeholder Secrets

If Secrets were previously applied from Git, Argo CD may **prune** them when they are removed from the repo (`prune: true` on `observability`). **Orphan** them first so your live tokens survive sync:

```bash
for s in prometheus-grafana-cloud-remote-write alloy-grafana-cloud-loki; do
  sudo k3s kubectl label secret -n monitoring "$s" \
    app.kubernetes.io/instance- \
    argocd.argoproj.io/instance- 2>/dev/null || true
done
```

Then `git pull`, let Argo sync `observability`, and confirm secrets still exist:

```bash
sudo k3s kubectl get secret -n monitoring \
  prometheus-grafana-cloud-remote-write alloy-grafana-cloud-loki
```

If a secret was deleted, recreate with the commands above.

## Prod (`ai-prod`)

Bundle secret for gateway-api + orchestrator: [docs/deploy-prod.md](../docs/deploy-prod.md), template `secrets/examples/layer-ai-prod-secrets.secret.example.yaml`.

## Rotation

Always use `kubectl create secret ... --dry-run=client -o yaml | kubectl apply -f -` and rollout restart Prometheus or Alloy. Do not re-add Secrets to `manifests/observability/`.
