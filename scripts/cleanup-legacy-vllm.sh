#!/usr/bin/env bash
# Delete pre-bundle vLLM Deployments/ReplicaSets left in the cluster (not in manifests/vllm).
# Safe to run while bundle pods (vllm-bundle-gpu-node-*) are Running.
set -euo pipefail

KUBECTL="${KUBECTL:-sudo k3s kubectl}"

echo "== before =="
$KUBECTL get deploy,rs -n vllm 2>/dev/null || true

# Standalone chat/embed/rerank Deployments from before the per-GPU bundle.
for ns in vllm ai; do
  for name in vllm inference-qwen25-7b embedding-bge-m3 rerank-bge-m3; do
    if $KUBECTL get deployment -n "$ns" "$name" &>/dev/null; then
      echo "Deleting deployment $ns/$name"
      $KUBECTL delete deployment -n "$ns" "$name" --wait=false
    fi
  done
done

# Legacy ReplicaSet(s) from Deployment "vllm" (pre-bundle); Argo shows as dashed until pruned.
$KUBECTL delete rs -n vllm -l 'app!=vllm-bundle' --ignore-not-found --wait=false 2>/dev/null || true
while read -r rs; do
  [[ -z "$rs" ]] && continue
  case "$rs" in
    vllm-bundle-gpu-node-*|vllm-bundle-gpu-node-*-*) continue ;;
  esac
  if [[ "$rs" =~ ^vllm-[0-9a-f]+$ ]]; then
    echo "Deleting legacy rs vllm/$rs"
    $KUBECTL delete rs -n vllm "$rs" --wait=false
  fi
done < <($KUBECTL get rs -n vllm -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

echo ""
echo "== after (expect only vllm-bundle-gpu-node-*) =="
$KUBECTL get deploy,rs,pods -n vllm -l app=vllm-bundle -o wide 2>/dev/null || true
echo ""
echo "Then in Argo: Refresh + Sync vllm-inference (prune enabled)."
