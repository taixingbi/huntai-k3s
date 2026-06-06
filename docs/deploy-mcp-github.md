# Deploy layer-mcp-github (dev)

Service image: [ghcr.io/taixingbi/layer-mcp-github-v1](https://github.com/taixingbi/layer-mcp-github-v1/pkgs/container/layer-mcp-github-v1) — source: [layer-mcp-github-v1](https://github.com/taixingbi/layer-mcp-github-v1). CI **Push to GHCR**: branch **`dev`** pins `manifests/tool/overlays/dev`, branch **`main`** pins `manifests/tool/overlays/prod` (`HUNTAI_K3S_PAT`). Prod rollout: [deploy-prod.md](deploy-prod.md) → `./scripts/sync-mcp-github-prod.sh`.

MCP over HTTP: `POST /v1/mcp` on port **8000** (use `/v1/mcp` not `/v1/mcp/`). NodePort **`30191`** on the dev control plane; in-cluster: `http://layer-mcp-github:8000/v1/mcp`. Tool `github_search` queries allowlisted GitHub repos and synthesizes answers via the inference gateway (`POST /v1/chat/completions` on **layer-gateway-inference**).

**SSE tokens:** direct MCP stream uses `event: delta` with `data.answer.text` (not RAG's `answer_delta`). See [sse-streaming-events.md](sse-streaming-events.md).

**Naming:** Service, Deployment, and `app` label: **`layer-mcp-github`** (same as `layer-orchestrator`, `layer-rag-query`, …). Image/repo/secret keep **`layer-mcp-github-v1`**.

Omit `repo` → all repos in upstream [`app/allowlist/repos.py`](https://github.com/taixingbi/layer-mcp-github-v1/blob/main/app/allowlist/repos.py). Streaming is default for `github_search`; set `stream:false` when you need buffered JSON.

Key endpoints:

- `GET /health` — liveness
- `GET /version` — build info (`[project].version` in upstream `pyproject.toml`)
- `GET /ready` — readiness (env + upstream checks)
- `GET /metrics` — Prometheus
- `POST /v1/mcp` — MCP JSON-RPC / SSE

Upstream: [schema.md](https://github.com/taixingbi/layer-mcp-github-v1/blob/main/docs/schema.md), [design.md](https://github.com/taixingbi/layer-mcp-github-v1/blob/main/docs/design.md), [smoke-test.md](https://github.com/taixingbi/layer-mcp-github-v1/blob/main/docs/smoke-test.md). Smoke curls below adapt `127.0.0.1:8000` → `192.168.86.179:30191`.

**`latency_ms` (tool-native):** `github_search` / SSE `done` use **flat** keys — `github_readme`, `github_search`, `chat`, `follow_up_chat`, `total`. That is correct for this MCP service. When the same tool is invoked via [orchestrator](deploy-orchestrator.md) **`github_repo_search`**, those timings appear under **`latency_ms.github`** on the orchestrator response, with **`latency_ms.total`** and **`latency_ms.intent_router`** at the orchestrator level (see [schema-request-response.md](https://github.com/taixingbi/layer-orchestrator-v1/blob/main/docs/schema-request-response.md)).

## Synthesis engine (`SYNTH_ENGINE`)

Default **`legacy`**: answers via **layer-gateway-inference** (`LLM_GATEWAY_BASE_URL` in the Deployment). Optional **`cursor_sdk`**: GitHub retrieval unchanged; synthesis via Cursor SDK (Ask-style read-only prompt). Requires **`CURSOR_API_KEY`** in the secret; `/ready` skips LLM gateway probe.

```bash
# Dev spike only — add to secret, then patch deployment env:
# SYNTH_ENGINE=cursor_sdk
# CURSOR_API_KEY from ~/.secrets/cursor-api-key
sudo k3s kubectl create secret generic layer-mcp-github-v1-secrets -n ai-dev \
  --from-file=GITHUB_TOKEN="$HOME/.secrets/github-token" \
  --from-file=CURSOR_API_KEY="$HOME/.secrets/cursor-api-key" \
  --dry-run=client -o yaml | sudo k3s kubectl apply -f -
```

MCP contract (`github_search`, orchestrator URL) is unchanged for either engine.

## Prerequisites

- **layer-gateway-inference** in `ai-dev` when `SYNTH_ENGINE=legacy` (`http://layer-gateway-inference:8000` or NodePort `30180`); see [deploy-gateway-inference.md](deploy-gateway-inference.md).
- Port map: [port.md](port.md) (`30191` dev; `30187`–`30190` reserved for future tools).
- GitHub PAT with **`repo`** scope (and access to repos in upstream allowlist under `taixingbi`).

## 1) Create secrets (required)

The dev manifest uses `envFrom.secretRef.name=layer-mcp-github-v1-secrets`. Create it in `ai-dev` before the Deployment can start.

```bash
mkdir -p ~/.secrets
chmod 700 ~/.secrets
printf '%s' 'ghp_YOUR_TOKEN' > ~/.secrets/github-token
chmod 600 ~/.secrets/github-token

sudo k3s kubectl create secret generic layer-mcp-github-v1-secrets -n ai-dev \
  --from-file=GITHUB_TOKEN="$HOME/.secrets/github-token" \
  --dry-run=client -o yaml | sudo k3s kubectl apply -f -
```

Optional `LLM_API_KEY` in the same Secret only if your inference gateway requires it (not set in the default manifest).

Non-secret env is in [manifests/tool/base/deployment.yaml](../manifests/tool/base/deployment.yaml). Full list: upstream [`.env.example`](https://github.com/taixingbi/layer-mcp-github-v1/blob/main/.env.example).

| Variable | Dev value |
|----------|-----------|
| `GITHUB_OWNER` | `taixingbi` |
| `LLM_GATEWAY_BASE_URL` | `http://layer-gateway-inference:8000` |
| `LLM_MODEL` | `Qwen/Qwen2.5-7B-Instruct` |
| `GITHUB_SEARCH_FOLLOW_UPS` | unset / `false` (default — skips second LLM pass; `latency_ms.follow_up_chat` omitted) |
| `GITHUB_FETCH_WORKERS` | `8` — parallel README / code-search threads |
| `GITHUB_README_CACHE_TTL_SEC` | `3600` — in-process README cache (`0` disables) |
| `GITHUB_REPO_ROUTING` | `true` — omit `repo` → rank ≤`GITHUB_ROUTE_MAX_REPOS` repos from question (not full allowlist) |
| `GITHUB_ROUTE_MAX_REPOS` | `5` |

Allowlisted repo short names are baked into the image ([`app/allowlist/repos.py`](https://github.com/taixingbi/layer-mcp-github-v1/blob/main/app/allowlist/repos.py)); expect **11** repos including `layer-orchestrator-v1`, `layer-mcp-github-v1`, and `k3s`.

## 2) Deploy via Argo CD (GitOps)

Managed by **`mcp-github-dev`** via [app-of-apps](deploy-gitops-argocd.md).

```bash
cd ~/shared/huntai-k3s
sudo k3s kubectl get application mcp-github-dev -n argocd
```

```bash
# optional: preload pinned tag from Git
TAG=$(grep newTag manifests/tool/overlays/dev/kustomization.yaml | sed 's/.*"\(.*\)".*/\1/')
sudo k3s ctr images pull "ghcr.io/taixingbi/layer-mcp-github-v1:${TAG}"

sudo k3s kubectl get pods,svc -n ai-dev -l app=layer-mcp-github -o wide
sudo k3s kubectl get svc -A -o wide | grep 30191
```

If the pod does not start:

```bash
sudo k3s kubectl describe pod -n ai-dev -l app=layer-mcp-github
sudo k3s kubectl logs -n ai-dev deploy/layer-mcp-github --tail=50
```

Pod logs on startup should mention MCP URL, LLM gateway, and default repo list (same as local `python -m app.main --http`).

## 3) Smoke tests

From a host that can reach NodePort `30191` (adjust IP if your server differs; default LAN control plane is `192.168.86.179`). `jq` is optional.

### 3.0 Ops — health, version, ready, metrics

```bash
curl -sS http://192.168.86.179:30191/health | jq .
echo
curl -sS http://192.168.86.179:30191/version | jq .
echo
curl -sS http://192.168.86.179:30191/ready | jq .
echo
curl -sS http://192.168.86.179:30191/metrics | head -n 20
echo
```

**Pass:** `/health` → `"status":"ok"`; `/version` → non-empty `version` (matches image tag / upstream `pyproject.toml`); `/ready` → `"status":"ready"` and all `checks` true when the Secret and inference gateway are reachable; `/metrics` → Prometheus text including `layer_mcp_github_info`.

### 3.1 MCP — list tools

```bash
curl -sS -X POST \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' \
  http://192.168.86.179:30191/v1/mcp | jq -r '.result.tools[].name' | sort
```

**Pass:** `github_search`. Use `/v1/mcp` not `/v1/mcp/`.

### 3.2 MCP — buffered (`stream: false`)

```bash
curl -sS --max-time 120 -X POST \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -d '{"jsonrpc":"2.0","id":"smoke-1","method":"tools/call","params":{"name":"github_search","arguments":{"repo":"layer-orchestrator-v1","question":"introduce this huntAi project","stream":false,"conversation_id":"conv_smoke_1","request_id":"req-smoke-1","session_id":"ses-smoke-1","trace_id":"trc-smoke-1"}}}' \
  http://192.168.86.179:30191/v1/mcp | jq '.result.structuredContent | {ok, answer, citations}'
```

**Pass:** `ok: true`, non-empty `answer` and `citations`.

### 3.3 MCP — SSE stream (default stream + `Accept: text/event-stream`)

Requires `Accept: text/event-stream` and `github_search` (stream defaults to true). Wire events: **`meta`**, **`delta`**, **`done`** (not RAG's `answer_delta`). Token text is in `data.answer.text`. Cross-service summary: [sse-streaming-events.md](sse-streaming-events.md).

```bash
curl -N -sS --max-time 120 -X POST http://192.168.86.179:30191/v1/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: text/event-stream" \
  -H "X-Request-Id: req-mcp-stream-1" \
  -H "X-Session-Id: ses-mcp-stream-1" \
  -H "X-Trace-Id: trc-mcp-stream-1" \
  -d '{
    "jsonrpc":"2.0",
    "id":"smoke-1s",
    "method":"tools/call",
    "params":{
      "name":"github_search",
      "arguments":{
        "repo":"https://github.com/taixingbi/layer-web-v1/tree/main/app/blog",
        "question":"introduce this huntAi project",
        "conversation_id":"conv_smoke_1s"
      }
    }
  }' | tee /tmp/mcp-stream.txt
```

**Pass:** SSE lines with `event: meta`, `event: delta` (`data.answer.text` chunks), `event: done`; first `meta` data has `.meta.request_id` `req-mcp-stream-1`.

**Final JSON from `done`:**

```bash
awk '/^event: done$/{p=1} p&&/^data: /{sub(/^data: /,""); print}' /tmp/mcp-stream.txt | tail -1 | jq '{ok, answer: (.answer|length), citations: (.citations|length)}'
```

### 3.4 MCP — correlation (`trace_id` optional)

```bash
curl -sS -X POST \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -d '{"jsonrpc":"2.0","id":"smoke-corr","method":"tools/call","params":{"name":"github_search","arguments":{"repo":"layer-orchestrator-v1","question":"One sentence.","stream":false}}}' \
  http://192.168.86.179:30191/v1/mcp | jq '.result.structuredContent | {request_id, session_id, trace_id, conversation_id}'
```

**Pass:** `request_id`, `session_id`, `conversation_id` non-empty strings; `trace_id` is `null` when not passed in arguments.

### 3.5 LLM gateway (inference NodePort)

Confirms the MCP pod can reach the same gateway the manifest uses in-cluster (`layer-gateway-inference:8000` → LAN `30180`):

```bash
curl -sS http://192.168.86.179:30180/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen/Qwen2.5-7B-Instruct","messages":[{"role":"user","content":"ping"}],"max_tokens":8}' \
  | jq '{has_choices: (.choices|length>0)}'
```

**Pass:** `has_choices: true`.

### 3.6 Optional — all repos (slow)

Omits `repo` → all allowlisted repos under `GITHUB_OWNER`. Dev vLLM uses `--max-model-len 2048`; without `repo`, evidence for every allowlisted repo can exceed that window and the inference gateway returns **400** on `/v1/chat/completions`. Prefer **§3.3** (single `repo`) for smoke tests, or deploy an MCP image that scales/truncates the LLM user body (`LLM_USER_BODY_MAX_CHARS`, default `4000`).

```bash
curl -N -sS --max-time 120 -X POST http://192.168.86.179:30191/v1/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: text/event-stream" \
  -H "X-Request-Id: req-mcp-stream-1" \
  -H "X-Session-Id: ses-mcp-stream-1" \
  -H "X-Trace-Id: trc-mcp-stream-1" \
  -H "X-User-Id: taixing" \
  -H "X-User-Roles: hr" \
  -H "X-User-Groups: engineering" \
  -H "X-User-Teams: rag-platform" \
  -d '{
    "jsonrpc":"2.0",
    "id":"smoke-1s",
    "method":"tools/call",
    "params":{
      "name":"github_search",
      "arguments":{
        "question":"in huntai, what  gateway for vllm design?",
        "conversation_id":"conv_smoke_1s"
      }
    }
  }' | tee /tmp/mcp-stream-all.txt
```

**Pass:** terminal `done` payload has `ok: true` and `repos` length **11** (current allowlist count in [`app/allowlist/repos.py`](https://github.com/taixingbi/layer-mcp-github-v1/blob/main/app/allowlist/repos.py)). **`latency_ms`** on `done` is tool-only (flat `github_*` / `chat` keys); it is not orchestrator wall time — use [deploy-orchestrator.md §4.5](deploy-orchestrator.md) for nested **`latency_ms.github`**.

### 3.7 Checklist

| Step | Endpoint | Expect |
|------|----------|--------|
| 1 | `GET /health` | `"status":"ok"` |
| 2 | `GET /version` | non-empty `version` |
| 3 | `GET /ready` | `"status":"ready"`, checks true |
| 4 | `GET /metrics` | Prometheus text; `layer_mcp_github_info` |
| 5 | `tools/list` on `/v1/mcp` | `github_search` |
| 6 | `github_search` buffered (`stream:false`) | `ok: true`, answer + citations |
| 7 | `github_search` SSE (default stream) | `meta` → optional `status` → `delta` (…) → `done` |
| 8 | correlation | ids present; `trace_id` null when omitted |
| 9 | `30180` `/v1/chat/completions` | `has_choices: true` |
| 10 | all repos (optional) | `repos` length = allowlist count |

During §3.2–3.3, pod logs should show GitHub readme/search and `POST .../v1/chat/completions` → `200 OK`. §3.3 SSE uses `/v1/mcp` (not a JSON-RPC envelope on the wire).

```bash
sudo k3s kubectl logs -n ai-dev deploy/layer-mcp-github -f --tail=30
```

## 4) Cursor / MCP clients

The container runs **HTTP MCP** (`python -m app.main --http`), not stdio. Point clients at:

- LAN: `http://192.168.86.179:30191/v1/mcp`
- Port-forward: `sudo k3s kubectl port-forward -n ai-dev svc/layer-mcp-github 8000:8000` → `http://127.0.0.1:8000/v1/mcp`

Enable MCP server **layer-mcp-github-v1** per upstream [`.cursor/mcp.json`](https://github.com/taixingbi/layer-mcp-github-v1/blob/main/.cursor/mcp.json).

## Troubleshooting

| Symptom | Check |
|---------|--------|
| `CreateContainerConfigError` | Secret `layer-mcp-github-v1-secrets` missing |
| Empty curl body | `/v1/mcp` not `/v1/mcp/` |
| `LLM gateway: (not set)` in pod logs | `LLM_GATEWAY_BASE_URL` in manifest; restart deployment |
| GitHub 401 | PAT `repo` scope; token in Secret |
| `repo not allowed` | `ALLOWED_REPOS` in [`app/allowlist/repos.py`](https://github.com/taixingbi/layer-mcp-github-v1/blob/main/app/allowlist/repos.py) + `GITHUB_OWNER=taixingbi` |
| `GET /ready` **503** | Secret `GITHUB_TOKEN`; inference gateway §3.5; `kubectl logs` |
| No `answer` / LLM errors | [deploy-gateway-inference.md](deploy-gateway-inference.md); §3.5 |
| `Not Acceptable` on `/v1/mcp` stream | Pull latest image; `Accept: text/event-stream` + `"stream": true`; startup log should mention SSE |
| Stale MCP behavior | `rollout restart deployment/layer-mcp-github -n ai-dev` |
| `spec.selector: field is immutable` | Delete old Deployment/Service, re-apply overlay — see below |

**One-time rename** (`layer-mcp-github-v1` → `layer-mcp-github`): Deployment `spec.selector` and Service names cannot be patched in place. Sync orchestrator after MCP is up. Expect ~30s downtime per namespace.

```bash
cd huntai-k3s
for NS in ai-dev ai-prod; do
  sudo k3s kubectl delete deployment,service layer-mcp-github-v1 -n "$NS" --ignore-not-found --wait=true
  sudo k3s kubectl delete deployment layer-mcp-github -n "$NS" --ignore-not-found --wait=true
done
sudo k3s kubectl apply -k manifests/tool/overlays/dev
sudo k3s kubectl apply -k manifests/tool/overlays/prod
sudo k3s kubectl apply -k manifests/orchestrator/overlays/dev
sudo k3s kubectl apply -k manifests/orchestrator/overlays/prod
sudo k3s kubectl -n ai-dev rollout status deployment/layer-mcp-github --timeout=120s
sudo k3s kubectl -n ai-prod rollout status deployment/layer-mcp-github --timeout=120s
```

NodePort:

- dev: `30191`
- prod (`ai-prod`): `30391`

## Prod (`ai-prod`)

Argo CD app **`mcp-github-prod`** → `manifests/tool/overlays/prod`. Prod orchestrator uses in-cluster `http://layer-mcp-github:8000` (same namespace). Inference still uses **`ai-dev`** gateway: `http://layer-gateway-inference.ai-dev.svc.cluster.local:8000`.

### Prod secret

```bash
sudo k3s kubectl create secret generic layer-mcp-github-v1-secrets -n ai-prod \
  --from-file=GITHUB_TOKEN="$HOME/.secrets/github-token" \
  --dry-run=client -o yaml | sudo k3s kubectl apply -f -
```

Use a prod-appropriate PAT or the same org token as dev if policy allows.

### Rollout

```bash
cd ~/shared/huntai-platform/huntai-k3s
./scripts/sync-mcp-github-prod.sh
# then re-sync orchestrator-prod if MCP URL patch changed
```
