# Deploy Alloy (Grafana Cloud Loki logs)

Managed by Argo CD Application `observability` together with Prometheus. Bootstrap via [deploy-gitops-argocd.md](deploy-gitops-argocd.md).

```bash
sudo k3s kubectl get application observability -n argocd
sudo k3s kubectl get pods -n monitoring -l app.kubernetes.io/name=alloy-logs -o wide
```

Patch Loki secret (`logs:write`) after apply:

```bash
sudo k3s kubectl create secret generic alloy-grafana-cloud-loki -n monitoring \
  --from-literal=loki-url='https://logs-prod-NNN.grafana.net/loki/api/v1/push' \
  --from-literal=loki-username='YOUR_LOKI_USER_ID' \
  --from-literal=api-key='glc_YOUR_TOKEN_HERE' \
  --dry-run=client -o yaml | sudo k3s kubectl apply -f -

sudo k3s kubectl rollout restart daemonset/alloy-logs -n monitoring
sudo k3s kubectl rollout status daemonset/alloy-logs -n monitoring
sudo k3s kubectl get pods -n monitoring -l app.kubernetes.io/name=alloy-logs -o wide
```

Notes:

- Keep real tokens out of git.
- If token contains `$`, single quotes avoid shell expansion mistakes.
- Current manifest uses `/-/ready` for liveness and runs as UID/GID `473` with writable `emptyDir` mounts for `/tmp` and `/var/lib/alloy/data`.
