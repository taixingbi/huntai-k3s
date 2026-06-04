#!/usr/bin/env bash
# Installs NVIDIA GPU Operator on the existing k3s cluster (Helm-based).
#
# Intended to run on server-node-1 (the k3s server), but it will manage the cluster remotely.
# Requires: curl, sudo, and network access to GitHub + NVIDIA Helm chart repo.
#
# Usage:
#   cd /path/to/k3s
#   sudo -E ./install-nvidia-gpu-operator.sh
#
# Environment overrides:
#   GPU_OPERATOR_VERSION         Helm chart/operator version (default: v25.3.3)
#   GPU_OPERATOR_NAMESPACE       Namespace for operator (default: gpu-operator)
#   GPU_NODE_NAMES              Comma-separated nodes to check allocatable on
#                               (default: gpu-node-1,gpu-node-2)
#
# Notes:
# - Uses your pre-installed NVIDIA driver (driver.enabled=false).
# - Allows Operator to install/configure NVIDIA Container Toolkit (toolkit.enabled=true).
# - Configures toolkit for k3s containerd paths (socket + config).

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run this script as root (sudo) so helm/k3s kubeconfig access works." >&2
  exit 1
fi

CLUSTER_KUBECONFIG="${K3S_KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

if [[ ! -f "${CLUSTER_KUBECONFIG}" ]]; then
  echo "k3s kubeconfig not found at ${CLUSTER_KUBECONFIG}" >&2
  echo "Expected default on k3s: /etc/rancher/k3s/k3s.yaml" >&2
  exit 1
fi

GPU_OPERATOR_VERSION="${GPU_OPERATOR_VERSION:-v25.3.3}"
GPU_OPERATOR_NAMESPACE="${GPU_OPERATOR_NAMESPACE:-gpu-operator}"
GPU_NODE_NAMES="${GPU_NODE_NAMES:-gpu-node-1,gpu-node-2}"
K3S_CONTAINERD_SOCKET="${K3S_CONTAINERD_SOCKET:-/run/k3s/containerd/containerd.sock}"
K3S_CONTAINERD_CONFIG="${K3S_CONTAINERD_CONFIG:-/var/lib/rancher/k3s/agent/etc/containerd/config.toml}"

echo "Installing NVIDIA GPU Operator:"
echo "  chart/operator version: ${GPU_OPERATOR_VERSION}"
echo "  namespace: ${GPU_OPERATOR_NAMESPACE}"
echo "  node allocatable checks: ${GPU_NODE_NAMES}"
echo "  containerd socket: ${K3S_CONTAINERD_SOCKET}"
echo "  containerd config: ${K3S_CONTAINERD_CONFIG}"
echo ""

if ! command -v helm >/dev/null 2>&1; then
  echo "Helm not found; installing Helm 3 (client-side) ..."
  tmp_get_helm="$(mktemp)"
  curl -fsSL -o "${tmp_get_helm}" https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
  chmod 700 "${tmp_get_helm}"
  "${tmp_get_helm}"
  rm -f "${tmp_get_helm}"
fi

echo "Helm version: $(helm version --short 2>/dev/null || helm version)"

echo "Adding NVIDIA Helm repo ..."
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia >/dev/null 2>&1 || true
helm repo update >/dev/null

echo "Ensuring namespace exists: ${GPU_OPERATOR_NAMESPACE}"
k3s kubectl create namespace "${GPU_OPERATOR_NAMESPACE}" >/dev/null 2>&1 || true

echo "Best-effort: labeling namespace for privileged pods (Pod Security Admission)"
kubectl_label_cmd=(k3s kubectl label --overwrite ns "${GPU_OPERATOR_NAMESPACE}" pod-security.kubernetes.io/enforce=privileged)
"${kubectl_label_cmd[@]}" >/dev/null 2>&1 || true

RELEASE_NAME="${GPU_OPERATOR_RELEASE_NAME:-nvidia-gpu-operator}"

echo "Installing/upgrading Helm release: ${RELEASE_NAME}"

HELM_BASE_ARGS=(
  --kubeconfig "${CLUSTER_KUBECONFIG}"
  -n "${GPU_OPERATOR_NAMESPACE}"
)
HELM_WAIT_ARGS=(
  --wait
  --timeout 10m0s
)

# `helm status` does not support `--wait` / `--timeout`, so keep install/upgrade flags separate.
HELM_OP_ARGS=(
  "${HELM_BASE_ARGS[@]}"
  "${HELM_WAIT_ARGS[@]}"
  --version "${GPU_OPERATOR_VERSION}"
  --set driver.enabled=false
  --set toolkit.enabled=true
  --set dcgmExporter.enabled=true
  --set "toolkit.env[0].name=CONTAINERD_SOCKET"
  --set "toolkit.env[0].value=${K3S_CONTAINERD_SOCKET}"
  --set "toolkit.env[1].name=CONTAINERD_CONFIG"
  --set "toolkit.env[1].value=${K3S_CONTAINERD_CONFIG}"
)
if helm status "${RELEASE_NAME}" "${HELM_BASE_ARGS[@]}" >/dev/null 2>&1; then
  helm upgrade "${RELEASE_NAME}" nvidia/gpu-operator "${HELM_OP_ARGS[@]}"
else
  helm install "${RELEASE_NAME}" nvidia/gpu-operator "${HELM_OP_ARGS[@]}"
fi

# Patch device plugin to use nvidia runtime (required on k3s so the plugin can see GPUs)
echo ""
echo "Patching device plugin DaemonSet with runtimeClassName: nvidia ..."
if k3s kubectl get daemonset nvidia-device-plugin-daemonset -n "${GPU_OPERATOR_NAMESPACE}" &>/dev/null; then
  k3s kubectl patch daemonset nvidia-device-plugin-daemonset -n "${GPU_OPERATOR_NAMESPACE}" \
    --type=merge \
    -p='{"spec":{"template":{"spec":{"runtimeClassName":"nvidia"}}}}' 2>/dev/null || \
  k3s kubectl patch daemonset nvidia-device-plugin-daemonset -n "${GPU_OPERATOR_NAMESPACE}" \
    --type='json' \
    -p='[{"op":"add","path":"/spec/template/spec/runtimeClassName","value":"nvidia"}]' 2>/dev/null || true
fi

echo ""
IFS=',' read -r -a gpu_nodes <<< "${GPU_NODE_NAMES}"
for gpu_node in "${gpu_nodes[@]}"; do
  gpu_node="${gpu_node#"${gpu_node%%[![:space:]]*}"}"
  gpu_node="${gpu_node%"${gpu_node##*[![:space:]]}"}"
  if [[ -z "${gpu_node}" ]]; then
    continue
  fi

  echo "Waiting for GPU resources to appear on node: ${gpu_node}"
  alloc_value=""
  for _ in $(seq 1 72); do
    # Use go-template; jsonpath indexing with dots is inconsistent across kubectl builds.
    alloc_value="$(
      k3s kubectl get node "${gpu_node}" \
        -o go-template='{{index .status.allocatable "nvidia.com/gpu"}}' 2>/dev/null || true
    )"
    if [[ "${alloc_value:-}" != "" && "${alloc_value:-}" != "<no value>" && "${alloc_value:-}" != "0" ]]; then
      break
    fi
    sleep 5
  done
  echo "Allocatable nvidia.com/gpu on ${gpu_node}: ${alloc_value:-<not-set>}"
done

echo ""
echo "Operator status (best-effort):"
k3s kubectl get pods -n "${GPU_OPERATOR_NAMESPACE}" -o wide 2>/dev/null || true

echo ""
echo "DCGM exporter (Prometheus scrapes gpu-operator namespace, port 9400):"
k3s kubectl get daemonset -n "${GPU_OPERATOR_NAMESPACE}" 2>/dev/null | grep -i dcgm || true
k3s kubectl get svc -n "${GPU_OPERATOR_NAMESPACE}" 2>/dev/null | grep -i dcgm || true
k3s kubectl get pods -n "${GPU_OPERATOR_NAMESPACE}" -l app=nvidia-dcgm-exporter -o wide 2>/dev/null \
  || k3s kubectl get pods -n "${GPU_OPERATOR_NAMESPACE}" 2>/dev/null | grep -i dcgm || true

echo ""
echo "Next: apply the provided sample manifest to validate GPU scheduling:"
echo "  sudo k3s kubectl apply -f manifests/gpu/gpu-vectoradd-sample.yaml"
echo ""
echo "After Docker dcgm-exporter is removed from GPU nodes, verify Prometheus targets:"
echo "  ./scripts/migrate-docker-dcgm-to-k3s.sh verify"
