#!/usr/bin/env bash
# Migrate GPU telemetry from host Docker dcgm-exporter to GPU Operator DCGM in k3s.
# Run on server-node-1 as root (sudo).
#
# Usage:
#   sudo ./scripts/migrate-docker-dcgm-to-k3s.sh verify
#   sudo ./scripts/migrate-docker-dcgm-to-k3s.sh decommission
#   sudo ./scripts/migrate-docker-dcgm-to-k3s.sh all
#
# Environment:
#   GPU_NODE_NAMES          default: gpu-node-1,gpu-node-2 (k8s node names)
#   GPU_NODE_SSH_HOSTS      optional: 192.168.86.173,192.168.86.176 (parallel to GPU_NODE_NAMES)
#   GPU_NODE_SSH_USER       if set, SSH to each GPU host to stop Docker (e.g. tb)
#   SKIP_PROMETHEUS_CHECK   set to 1 to skip Prometheus target verification

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo $0 $*" >&2
  exit 1
fi

GPU_NODE_NAMES="${GPU_NODE_NAMES:-gpu-node-1,gpu-node-2}"
ACTION="${1:-verify}"

verify_gpu_operator_dcgm() {
  echo "==> GPU Operator DCGM (namespace gpu-operator)"
  k3s kubectl get pods -n gpu-operator -o wide
  echo
  k3s kubectl get daemonset -n gpu-operator | grep -i dcgm || {
    echo "ERROR: no DCGM DaemonSet in gpu-operator. Run:" >&2
    echo "  sudo -E ./scripts/install-nvidia-gpu-operator.sh" >&2
    return 1
  }
  k3s kubectl get svc -n gpu-operator | grep -i dcgm || {
    echo "ERROR: no DCGM Service in gpu-operator" >&2
    return 1
  }

  local missing=0
  IFS=',' read -r -a gpu_nodes <<< "${GPU_NODE_NAMES}"
  for node in "${gpu_nodes[@]}"; do
    node="${node// /}"
    [[ -z "$node" ]] && continue
    if ! k3s kubectl get pods -n gpu-operator -o wide --field-selector "spec.nodeName=${node}" 2>/dev/null | grep -qi dcgm; then
      echo "ERROR: no DCGM pod on node ${node}" >&2
      missing=1
    fi
  done
  if [[ "$missing" -ne 0 ]]; then
    return 1
  fi
  echo "PASS: DCGM DaemonSet present on GPU nodes"
}

verify_prometheus_targets() {
  if [[ "${SKIP_PROMETHEUS_CHECK:-0}" == "1" ]]; then
    echo "==> Skipping Prometheus check (SKIP_PROMETHEUS_CHECK=1)"
    return 0
  fi

  echo "==> Prometheus dcgm-exporter targets"
  if ! k3s kubectl get application observability -n argocd &>/dev/null; then
    echo "WARN: observability Argo app not found; sync manifests/observability or apply app-of-apps"
  fi

  local prom_pod
  prom_pod="$(k3s kubectl get pod -n monitoring -l app=prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -z "$prom_pod" ]]; then
    echo "WARN: Prometheus pod not found in monitoring; skip target check"
    return 0
  fi

  k3s kubectl exec -n monitoring "$prom_pod" -- wget -qO- \
    'http://127.0.0.1:9090/api/v1/targets?state=active' 2>/dev/null \
    | python3 -c "
import json, sys
data = json.load(sys.stdin)
active = data.get('data', {}).get('activeTargets', [])
dcgm = [t for t in active if t.get('labels', {}).get('job') == 'dcgm-exporter']
up = [t for t in dcgm if t.get('health') == 'up']
print(f'dcgm-exporter targets: {len(dcgm)} total, {len(up)} up')
for t in up:
    labels = t.get('labels', {})
    print(f\"  up: node={labels.get('kubernetes_node', '?')} pod={labels.get('kubernetes_pod_name', '?')}\")
if len(up) < 1:
    sys.exit(1)
" || {
    echo "ERROR: Prometheus has no healthy dcgm-exporter targets" >&2
    echo "Fix GPU Operator DCGM before stopping Docker dcgm-exporter" >&2
    return 1
  }
  echo "PASS: Prometheus scraping in-cluster DCGM"
}

stop_docker_on_node() {
  local node="$1"
  local ssh_host="${2:-$node}"
  local cmd='
set -e
if docker ps -a --filter name=dcgm-exporter --format "{{.Names}}" | grep -q .; then
  echo "Stopping Docker dcgm-exporter ..."
  docker stop dcgm-exporter 2>/dev/null || true
  docker rm dcgm-exporter 2>/dev/null || true
  echo "Removed Docker dcgm-exporter"
else
  echo "No Docker dcgm-exporter container"
fi
systemctl list-units --type=service 2>/dev/null | grep -i dcgm || true
'

  if [[ -n "${GPU_NODE_SSH_USER:-}" ]]; then
    echo "==> ${node} (${ssh_host}): SSH decommission (user=${GPU_NODE_SSH_USER})"
    ssh -o StrictHostKeyChecking=accept-new "${GPU_NODE_SSH_USER}@${ssh_host}" "sudo bash -s" <<< "$cmd"
  else
    echo "==> ${node}: run on GPU node (set GPU_NODE_SSH_USER for remote stop):"
    echo "  ssh ${ssh_host} 'sudo docker stop dcgm-exporter; sudo docker rm dcgm-exporter'"
  fi
}

decommission_docker_dcgm() {
  verify_gpu_operator_dcgm
  verify_prometheus_targets

  IFS=',' read -r -a gpu_nodes <<< "${GPU_NODE_NAMES}"
  IFS=',' read -r -a ssh_hosts <<< "${GPU_NODE_SSH_HOSTS:-}"
  local i=0
  for node in "${gpu_nodes[@]}"; do
    node="${node// /}"
    [[ -z "$node" ]] && continue
    local ssh_host="${ssh_hosts[$i]:-$node}"
    ssh_host="${ssh_host// /}"
    stop_docker_on_node "$node" "$ssh_host"
    i=$((i + 1))
  done

  if [[ -z "${GPU_NODE_SSH_USER:-}" ]]; then
    echo ""
    echo "Set GPU_NODE_SSH_USER=tb and GPU_NODE_SSH_HOSTS=192.168.86.173,192.168.86.176"
    echo "then re-run: sudo -E $0 decommission"
  fi

  echo ""
  echo "Re-verify after Docker removal:"
  echo "  sudo $0 verify"
}

case "$ACTION" in
  verify)
    verify_gpu_operator_dcgm
    verify_prometheus_targets
    ;;
  decommission)
    decommission_docker_dcgm
    ;;
  all)
    verify_gpu_operator_dcgm || {
      echo "Installing/upgrading GPU Operator with DCGM enabled ..."
      "${ROOT}/scripts/install-nvidia-gpu-operator.sh"
      verify_gpu_operator_dcgm
    }
    verify_prometheus_targets
    decommission_docker_dcgm
    ;;
  *)
    echo "usage: sudo $0 {verify|decommission|all}" >&2
    exit 1
    ;;
esac
