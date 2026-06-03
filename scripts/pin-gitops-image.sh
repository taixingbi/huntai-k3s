#!/usr/bin/env bash
# Pin kustomize overlay images[] newTag + digest; verify images[0].name matches IMAGE.
set -euo pipefail

KUSTOMIZE_FILE="${1:?kustomization.yaml path}"
IMAGE="${2:?ghcr.io/owner/repo}"
TAG="${3:?tag}"
DIGEST="${4:?digest sha256:...}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "${KUSTOMIZE_FILE}" ]; then
  echo "Missing ${KUSTOMIZE_FILE}" >&2
  exit 1
fi

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
