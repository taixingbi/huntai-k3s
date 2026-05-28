#!/usr/bin/env bash

set -euo pipefail

ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
ARGOCD_WEBHOOK_URL="${ARGOCD_WEBHOOK_URL:-https://argocd.taixingai.com/api/webhook}"
GITHUB_REPO="${GITHUB_REPO:-taixingbi/huntai-k3s}"
WEBHOOK_EVENTS='["push"]'

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 1
  fi
}

require_cmd openssl

if [[ -z "${WEBHOOK_SECRET:-}" ]]; then
  WEBHOOK_SECRET="$(openssl rand -hex 20)"
fi

echo "Using webhook URL: ${ARGOCD_WEBHOOK_URL}"
echo "Using repo: ${GITHUB_REPO}"
echo
echo "Generated webhook secret (store securely):"
echo "${WEBHOOK_SECRET}"
echo

echo "Patching Argo CD secret key webhook.github.secret..."
echo "Command:"
echo "sudo k3s kubectl -n ${ARGOCD_NAMESPACE} patch secret argocd-secret --type merge -p '{\"stringData\":{\"webhook.github.secret\":\"***\"}}'"
echo
sudo k3s kubectl -n "${ARGOCD_NAMESPACE}" patch secret argocd-secret \
  --type merge \
  -p "{\"stringData\":{\"webhook.github.secret\":\"${WEBHOOK_SECRET}\"}}"
echo "Argo CD secret patched."
echo

if command -v gh >/dev/null 2>&1; then
  echo "Creating GitHub webhook with gh api..."
  gh api "repos/${GITHUB_REPO}/hooks" \
    --method POST \
    -H "Accept: application/vnd.github+json" \
    -f name="web" \
    -f active=true \
    -f events="${WEBHOOK_EVENTS}" \
    -f "config[url]=${ARGOCD_WEBHOOK_URL}" \
    -f "config[content_type]=json" \
    -f "config[insecure_ssl]=0" \
    -f "config[secret]=${WEBHOOK_SECRET}" >/dev/null
  echo "Webhook created via GitHub API."
else
  echo "gh CLI not found. Add webhook manually in GitHub UI:"
  echo "  Repo Settings -> Webhooks -> Add webhook"
  echo "  Payload URL: ${ARGOCD_WEBHOOK_URL}"
  echo "  Content type: application/json"
  echo "  Secret: ${WEBHOOK_SECRET}"
  echo "  Events: Just the push event"
fi
echo
echo "Done. Verify with:"
echo "  sudo k3s kubectl get application orchestrator-dev -n ${ARGOCD_NAMESPACE} -o jsonpath='{.status.reconciledAt}{\"\\n\"}{.status.sync.status}{\"\\n\"}'"
