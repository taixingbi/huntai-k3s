# Backup and restore

Homelab dev cluster — manual procedures for state that lives outside Git.

## Qdrant (in-cluster)

**Data:** PVC `qdrant-data` in `ai-dev` (`local-path` on the node where the pod runs).

**Snapshot via API** (pod running):

```bash
QDRANT_POD=$(sudo k3s kubectl get pod -n ai-dev -l app=qdrant -o jsonpath='{.items[0].metadata.name}')
sudo k3s kubectl exec -n ai-dev "$QDRANT_POD" -- \
  curl -sS -X POST 'http://127.0.0.1:6333/collections/taixing_knowledge_dev/snapshots'
```

List snapshots and download per [Qdrant snapshot docs](https://qdrant.tech/documentation/concepts/snapshots/).

**Restore:** create collection if needed, upload snapshot, or re-run [layer-rag-ingest-v1](https://github.com/taixingbi/layer-rag-ingest-v1) ingest for dev.

**Legacy host Qdrant** (`192.168.86.179:6333`): back up before switching to in-cluster — see [deploy-qdrant.md](deploy-qdrant.md).

## Prometheus TSDB

**Data:** PVC `prometheus-data` in `monitoring` (`local-path`).

```bash
# Example: copy TSDB dir while Prometheus scaled to 0 (brief metrics gap)
sudo k3s kubectl scale deployment/prometheus -n monitoring --replicas=0
sudo k3s kubectl get pvc prometheus-data -n monitoring
# On the node hosting the PV, archive the volume path (k3s local-path layout varies)
sudo k3s kubectl scale deployment/prometheus -n monitoring --replicas=1
```

Long-term metrics also live in **Grafana Cloud** (remote_write).

## Kubernetes secrets

Not in Git. Export for disaster recovery (store encrypted offline):

```bash
sudo k3s kubectl get secret layer-gateway-api-secrets -n ai-dev -o yaml > gateway-api-secrets.backup.yaml
# Repeat for secrets in docs/cluster-secrets.md — delete files after secure storage
```

## Cloudflare tunnel

**File:** `~/.cloudflared/<tunnel-id>.json` on the control plane — back up separately from the cluster. Recreate `cloudflared-tunnel-credentials` Secret if lost ([deploy-dev-cloudflare-tunnel.md](deploy-dev-cloudflare-tunnel.md)).

## Full cluster rebuild order

1. Install k3s + GPU operator ([README.md](../README.md))
2. Install Argo CD + create secrets ([deploy-gitops-argocd.md](deploy-gitops-argocd.md), [cluster-secrets.md](cluster-secrets.md))
3. `kubectl apply -f argocd/app-of-apps.yaml`
4. Restore Qdrant snapshots / re-ingest
5. Re-create secrets from backup if needed
