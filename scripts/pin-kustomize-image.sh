#!/usr/bin/env bash
# Pin kustomize images[] newTag and digest (used by service CI update-gitops jobs).
set -euo pipefail

KUSTOMIZE_FILE="${1:?kustomization.yaml path}"
TAG="${2:?tag}"
DIGEST="${3:?digest sha256:...}"

if [ ! -f "${KUSTOMIZE_FILE}" ]; then
  echo "Missing ${KUSTOMIZE_FILE}" >&2
  exit 1
fi

if ! grep -q '^images:' "${KUSTOMIZE_FILE}"; then
  echo "Missing images: block in ${KUSTOMIZE_FILE}" >&2
  exit 1
fi

if ! grep -qE '^[[:space:]]*newTag:' "${KUSTOMIZE_FILE}"; then
  echo "Missing newTag in ${KUSTOMIZE_FILE}" >&2
  exit 1
fi

sed -i -E "s|^([[:space:]]*newTag:[[:space:]]*).*$|\1\"${TAG}\"|" "${KUSTOMIZE_FILE}"

if grep -qE '^[[:space:]]*digest:' "${KUSTOMIZE_FILE}"; then
  sed -i -E "s|^([[:space:]]*digest:[[:space:]]*).*$|\1\"${DIGEST}\"|" "${KUSTOMIZE_FILE}"
else
  sed -i -E "/^[[:space:]]*newTag:/a\\    digest: \"${DIGEST}\"" "${KUSTOMIZE_FILE}"
fi

grep -q "newTag: \"${TAG}\"" "${KUSTOMIZE_FILE}" || {
  echo "newTag was not updated to ${TAG}" >&2
  exit 1
}
grep -q "digest: \"${DIGEST}\"" "${KUSTOMIZE_FILE}" || {
  echo "digest was not updated to ${DIGEST}" >&2
  exit 1
}
