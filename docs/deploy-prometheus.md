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
