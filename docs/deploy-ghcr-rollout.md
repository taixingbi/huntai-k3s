# GHCR rollout (one-time and verification)

Container images for HuntAI services are published to **GitHub Container Registry** (`ghcr.io/taixingbi/<repo>`) by each service repo’s **Push to GHCR** workflow. GitOps pins `newTag` and `digest` in `huntai-k3s` via `scripts/pin-kustomize-image.sh` / `scripts/pin-gitops-image.sh`.

## One-time (GitHub org / packages)

1. **Org Actions → General → Workflow permissions:** allow workflows to write packages (or rely on per-repo `packages: write` in `docker-push.yml`).
2. After the **first successful push** for each repo, open the package under **GitHub → Packages** (e.g. `layer-orchestrator-v1`) and set visibility to **Public** so the cluster can pull without an imagePullSecret.
3. Remove obsolete repo secrets **`DOCKERHUB_USERNAME`** and **`DOCKERHUB_TOKEN`** once GHCR is live. Keep **`HUNTAI_K3S_PAT`** for GitOps commits.

## Cluster pull (k3s)

Public GHCR images should pull without credentials:

```bash
sudo k3s ctr images pull ghcr.io/taixingbi/layer-orchestrator-v1:latest
```

If pull fails with 401/403, the package is still private — set it Public or add an `imagePullSecret` for `ghcr.io`.

## Verify GitOps pin

After a `main` push in a service repo:

1. Actions: **Push to GHCR** → `push` job succeeds; `update-gitops` commits to `taixingbi/huntai-k3s`.
2. Overlay e.g. `manifests/orchestrator/overlays/dev/kustomization.yaml` has updated `newTag` and `digest: "sha256:..."`.
3. Argo CD syncs the Application; Deployment rolls out:

```bash
kubectl -n ai-dev get deploy layer-orchestrator-v1 -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

Expect `ghcr.io/taixingbi/layer-orchestrator-v1:<tag>@sha256:<digest>` (kustomize renders tag + digest).

## Rollout order (suggested)

1. Merge and push **huntai-k3s** manifest changes (`ghcr.io/...` image names).
2. Merge service repos (workflows + any README); trigger **Push to GHCR** per service (or push to `main`).
3. Confirm Argo CD healthy for `ai-dev` apps; spot-check gateway inference `/version` if needed.

## Deferred (not in this migration)

- Unified `/version` on every service
- GHCR tag cleanup workflow
- cosign / provenance signing
