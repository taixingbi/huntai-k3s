#!/usr/bin/env bash
# Commit GitOps manifest pin(s) and push to main with rebase + retry (concurrent CI safe).
set -euo pipefail

if [ -z "${COMMIT_MSG:-}" ]; then
  echo "COMMIT_MSG is required" >&2
  exit 1
fi

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

if git diff --quiet; then
  echo "No manifest change; skip commit"
  exit 0
fi

if [ "$#" -gt 0 ]; then
  git add "$@"
elif [ -f .gitops-target-file ]; then
  git add "$(sed -n '1p' .gitops-target-file)"
else
  echo "No paths to add (pass files or create .gitops-target-file)" >&2
  exit 1
fi

git commit -m "${COMMIT_MSG}"

MAX_ATTEMPTS=5
for attempt in $(seq 1 "${MAX_ATTEMPTS}"); do
  git pull --rebase origin main
  if git push origin HEAD:main; then
    echo "Pushed to origin/main"
    exit 0
  fi
  echo "Push rejected (attempt ${attempt}/${MAX_ATTEMPTS}), retrying..."
  sleep $((attempt * 3))
done

echo "Failed to push huntai-k3s after ${MAX_ATTEMPTS} attempts" >&2
exit 1
