# Deploy Qdrant (dev)

Vector database for RAG. GitOps: Argo CD Application **`qdrant-dev`** (sync wave **2**, before `rag-query-dev`).

In-cluster: **`http://qdrant:6333`** in **`ai-dev`**. Data: PVC **`qdrant-data`** (`local-path`, 20Gi). RAG uses `QDRANT_URL=http://qdrant:6333` — do not point pods at host Docker unless you are temporarily bridging (see [Migrating from host Qdrant](#migrating-from-host-qdrant-192168861796333)).

## 1) Register Argo Application

If `qdrant-dev` is missing (common when apps were applied individually instead of `app-of-apps`):

```bash
cd ~/shared/huntai-platform/huntai-k3s
git pull origin main

sudo k3s kubectl apply -f argocd/applications/qdrant-dev.yaml
```

Optional — manage all apps from Git going forward:

```bash
sudo k3s kubectl apply -f argocd/app-of-apps.yaml
```

## 2) Wait for Qdrant

```bash
sudo k3s kubectl get application qdrant-dev -n argocd
sudo k3s kubectl get pods,svc,pvc -n ai-dev -l app=qdrant
sudo k3s kubectl rollout status deploy/qdrant -n ai-dev --timeout=5m
```

**Pass:** Application **Synced** / **Healthy**; pod **`Running`**; Service **`qdrant`** port **6333**; PVC **`qdrant-data`** **Bound**.

Pod prefers **`server-node-1`** (same node as legacy host Docker Qdrant).

## 3) Smoke test

ClusterIP from the control plane:

```bash
curl -sS http://$(sudo k3s kubectl get svc qdrant -n ai-dev -o jsonpath='{.spec.clusterIP}'):6333/collections | jq .
```

DNS from a pod in **`ai-dev`** (same path RAG uses):

```bash
sudo k3s kubectl run -n ai-dev qdrant-curl --rm -it --restart=Never --image=curlimages/curl:8.5.0 -- \
  curl -sS http://qdrant:6333/collections | jq .
```

**Pass:** HTTP 200, `"status":"ok"`, `result.collections` array (empty before migration is fine).

## 4) Verify RAG can reach Qdrant

```bash
curl -sS http://192.168.86.179:30183/ready | jq .
```

**Pass:** `"status":"ready"`. If **`not_ready`** with Qdrant errors, re-check steps 2–3.

## Migrating from host Qdrant (`192.168.86.179:6333`)

Use this when **host Docker Qdrant** already has collections (e.g. `taixing_knowledge_dev`) and you are moving to in-cluster Qdrant.

**Order:** deploy in-cluster Qdrant first (steps 1–2), migrate data, verify RAG, then stop host Docker.

### A) List collections on host

```bash
curl -sS http://192.168.86.179:6333/collections | jq -r '.result.collections[].name'
```

Note every collection RAG needs (typically **`taixing_knowledge_dev`** with `ENV=dev`).

### B) Snapshot + download (per collection)

Replace `COLLECTION` (e.g. `taixing_knowledge_dev`):

```bash
COLLECTION=taixing_knowledge_dev

curl -sS -X POST "http://192.168.86.179:6333/collections/${COLLECTION}/snapshots" | jq .

SNAPSHOT=$(curl -sS "http://192.168.86.179:6333/collections/${COLLECTION}/snapshots" \
  | jq -r '.result[-1].name')

curl -sS -o "/tmp/${COLLECTION}-${SNAPSHOT}.snapshot" \
  "http://192.168.86.179:6333/collections/${COLLECTION}/snapshots/${SNAPSHOT}"

ls -lh "/tmp/${COLLECTION}-${SNAPSHOT}.snapshot"
```

### C) Upload into in-cluster Qdrant

Port-forward in-cluster Qdrant to localhost (leave running in a second terminal):

```bash
sudo k3s kubectl port-forward -n ai-dev svc/qdrant 6333:6333
```

Upload (creates/restores the collection from snapshot):

```bash
COLLECTION=taixing_knowledge_dev
SNAPSHOT_FILE=/tmp/${COLLECTION}-*.snapshot   # adjust to your file path

curl -sS -X POST "http://127.0.0.1:6333/collections/${COLLECTION}/snapshots/upload?wait=true" \
  -H "Content-Type: multipart/form-data" \
  -F "snapshot=@${SNAPSHOT_FILE}" | jq .
```

Verify:

```bash
curl -sS http://127.0.0.1:6333/collections/${COLLECTION} | jq '.result.points_count'
```

### D) Cutover checks

```bash
# in-cluster DNS (no port-forward)
sudo k3s kubectl run -n ai-dev qdrant-curl --rm -it --restart=Never --image=curlimages/curl:8.5.0 -- \
  curl -sS "http://qdrant:6333/collections/${COLLECTION}" | jq '.result.points_count'

curl -sS http://192.168.86.179:30183/ready | jq .
```

Retry RAG query ([deploy-rag-query.md §3.1](deploy-rag-query.md#31-post-v1ragquery-sse-stream-default)).

### E) Decommission host Docker Qdrant (after cutover)

Only after in-cluster data and RAG smokes pass:

```bash
sudo docker stop qdrant
# optional: sudo docker rm qdrant   — after you confirm backups/snapshots are safe
```

Do **not** run host and in-cluster Qdrant on the same node long term unless you use different ports and know which clients point where.

Fresh dev cluster with no host data: skip §A–C; run [layer-rag-ingest-v1](https://github.com/taixingbi/layer-rag-ingest-v1) ingest after step 3.

## Troubleshooting

| Symptom | Likely cause | Action |
|---------|----------------|--------|
| `qdrant-dev` **NotFound** in Argo | App never registered | `kubectl apply -f argocd/applications/qdrant-dev.yaml` |
| PVC **Pending** | No `local-path` StorageClass | `kubectl get sc`; install/configure local-path provisioner |
| Pod **Pending** | Node affinity / resources | `kubectl describe pod -n ai-dev -l app=qdrant` |
| RAG **`Name or service not known`** | No in-cluster `qdrant` Service | Complete steps 1–2 |
| RAG **`/ready` ok**, empty answers | Collection missing or empty | Migrate or re-ingest `taixing_knowledge_dev` |

Backups: [backup-restore.md](backup-restore.md).

## Related

- RAG consumer: [deploy-rag-query.md](deploy-rag-query.md)
- GitOps bootstrap: [deploy-gitops-argocd.md](deploy-gitops-argocd.md)
