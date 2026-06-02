#!/usr/bin/env bash
# Pin dev GitOps: kustomize overlay (newTag + digest) or legacy Deployment (image@digest).
set -euo pipefail

KUSTOMIZE_FILE="${1:?kustomization.yaml path}"
LEGACY_FILE="${2:-}"
IMAGE="${3:?ghcr.io/owner/repo}"
TAG="${4:?tag}"
DIGEST="${5:?digest sha256:...}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "${KUSTOMIZE_FILE}" ]; then
  if ! grep -q '^images:' "${KUSTOMIZE_FILE}"; then
    echo "Missing images: block in ${KUSTOMIZE_FILE}" >&2
    exit 1
  fi
  ACTUAL="$(grep -E '^\s+-\s+name:' "${KUSTOMIZE_FILE}" | head -1 | sed -E 's/^[[:space:]]*-[[:space:]]*name:[[:space:]]*//;s/"//g;s/[[:space:]]*$//')"
  if [ "${ACTUAL}" != "${IMAGE}" ]; then
    echo "Unexpected images[0].name: '${ACTUAL}' (expected '${IMAGE}')" >&2
    exit 1
  fi
  bash "${SCRIPT_DIR}/pin-kustomize-image.sh" "${KUSTOMIZE_FILE}" "${TAG}" "${DIGEST}"
  printf '%s\n' "${KUSTOMIZE_FILE}" > .gitops-target-file
  printf '%s\n' kustomize > .gitops-target-mode
elif [ -n "${LEGACY_FILE}" ] && [ -f "${LEGACY_FILE}" ]; then
  sed -i -E "s|^([[:space:]]*image:[[:space:]]*).*|\1${IMAGE}@${DIGEST}|" "${LEGACY_FILE}"
  grep -q "${IMAGE}@${DIGEST}" "${LEGACY_FILE}" || {
    echo "image was not updated to ${IMAGE}@${DIGEST}" >&2
    exit 1
  }
  printf '%s\n' "${LEGACY_FILE}" > .gitops-target-file
  printf '%s\n' legacy > .gitops-target-mode
else
  echo "Missing ${KUSTOMIZE_FILE}${LEGACY_FILE:+ and ${LEGACY_FILE}}" >&2
  exit 1
fi
