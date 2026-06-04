#!/usr/bin/env bash
# Fetch upstream Grafana JSON from layer-observability-grafana for diff/merge.
# Does not overwrite huntai forks unless you pass --apply-safe (embedding, gpu only).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DASH="${ROOT}/grafana-import/dashboard"
UP="${DASH}/.upstream"
BASE="https://raw.githubusercontent.com/taixingbi/layer-observability-grafana/main"

mkdir -p "$UP"

fetch() {
  local rel="$1"
  local out="$2"
  echo "→ $BASE/$rel"
  curl -fsSL "$BASE/$rel" -o "$out"
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

  (no args)     Download upstream snapshots to grafana-import/dashboard/.upstream/
  --diff        Diff local dashboard/*.json vs .upstream/ (where upstream exists)
  --apply-safe  Overwrite embedding.json and gpu.json from upstream (inference is NEVER touched)
  --print-versions
                Print huntai dashboard version fields (see grafana-import/VERSIONS.md)

Fork policy:
  inference.json  — huntai fork (base/sft/dpo); upstream saved as .upstream/inference.json only
  reranker.json   — huntai-only
  loki-logs-http.json — huntai-only
EOF
}

cmd="${1:-fetch}"

case "$cmd" in
  fetch|"")
    fetch dashboards/inference.json "$UP/inference.json"
    fetch dashboards/embedding.json "$UP/embedding.json"
    fetch dashboards/gpu.json "$UP/gpu.json"
    echo "Done. Upstream snapshots in $UP"
    echo "See grafana-import/VERSIONS.md and merge forks manually (inference) or: $0 --apply-safe"
    ;;
  --diff)
    for f in inference embedding gpu; do
      up="$UP/${f}.json"
      loc="$DASH/${f}.json"
      if [[ -f "$up" && -f "$loc" ]]; then
        echo "=== diff $f.json ==="
        diff -u "$up" "$loc" || true
      fi
    done
    ;;
  --apply-safe)
    for f in embedding gpu; do
      if [[ -f "$UP/${f}.json" ]]; then
        cp "$UP/${f}.json" "$DASH/${f}.json"
        echo "Applied upstream → dashboard/${f}.json (re-check VERSIONS.md and bump version if needed)"
      fi
    done
    ;;
  --print-versions)
    command -v jq >/dev/null || { echo "jq required"; exit 1; }
    for j in "$DASH"/*.json; do
      [[ -f "$j" ]] || continue
      jq -r '"\(.title // "?")  uid=\(.uid)  version=\(.version)  tags=\(.tags|join(","))"' "$j"
    done
    ;;
  -h|--help)
    usage
    ;;
  *)
    echo "Unknown option: $cmd" >&2
    usage >&2
    exit 1
    ;;
esac
