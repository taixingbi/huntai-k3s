#!/usr/bin/env bash
# Build all kustomize roots to catch YAML/schema errors before apply.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl required (kustomize build)" >&2
  exit 1
fi

PATHS=(
  argocd
  manifests/vllm
  manifests/observability
  manifests/qdrant/overlays/dev
  manifests/gateway-inference/overlays/dev
  manifests/gateway-embedding/overlays/dev
  manifests/gateway-reranker/overlays/dev
  manifests/gateway-api/overlays/dev
  manifests/orchestrator/overlays/dev
  manifests/rag/overlays/dev
  manifests/web/overlays/dev
  manifests/tool/overlays/dev
  manifests/ingress/overlays/dev
  manifests/ingress/overlays/prod
  manifests/gateway-api/overlays/prod
  manifests/orchestrator/overlays/prod
  manifests/rag/overlays/prod
  manifests/web/overlays/prod
)

for p in "${PATHS[@]}"; do
  echo "kustomize build $p"
  kubectl kustomize "$p" >/dev/null
done

echo "OK: ${#PATHS[@]} kustomize paths"
