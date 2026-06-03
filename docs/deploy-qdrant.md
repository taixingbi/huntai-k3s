# Deploy Qdrant (dev)

Vector database for RAG. GitOps: Argo CD Application `qdrant-dev` (sync wave **2**, before `rag-query-dev`).

In-cluster: `http://qdrant:6333` in `ai-dev`. Data: PVC `qdrant-data` (`local-path`, 20Gi).

## Deploy

Bootstrap is via [deploy-gitops-argocd.md](deploy-gitops-argocd.md) (`app-of-apps`). Verify:

```bash
sudo k3s kubectl get application qdrant-dev -n argocd
sudo k3s kubectl get pods,svc,pvc -n ai-dev -l app=qdrant
curl -sS http://192.168.86.179:30183/ready | jq .   # RAG /ready checks Qdrant after rollout
```

## Migrating from host Qdrant (`192.168.86.179:6333`)

If collections already exist on the old host instance:

1. Snapshot or export collections from the host Qdrant (see [backup-restore.md](backup-restore.md)).
2. Sync `qdrant-dev` and wait for PVC + pod `Running`.
3. Import collections into in-cluster Qdrant (same collection names, e.g. `taixing_knowledge_dev`).
4. RAG manifest uses `QDRANT_URL=http://qdrant:6333` — no LAN IP in pods.

Fresh dev cluster: skip migration; run ingest after Qdrant is up.

## Smoke test

```bash
curl -sS http://$(sudo k3s kubectl get svc qdrant -n ai-dev -o jsonpath='{.spec.clusterIP}'):6333/collections | jq .
```

From a pod in `ai-dev`:

```bash
sudo k3s kubectl run -n ai-dev qdrant-curl --rm -it --restart=Never --image=curlimages/curl:8.5.0 -- \
  curl -sS http://qdrant:6333/collections
```
