# Deploy layer-mcp-github-v1 (dev)

Service image: [taixingbi/layer-mcp-github-v1](https://hub.docker.com/r/taixingbi/layer-mcp-github-v1) — source: [layer-mcp-github-v1](https://github.com/taixingbi/layer-mcp-github-v1)

MCP over HTTP: `POST /v1/mcp` on port **8000** (use `/v1/mcp` not `/v1/mcp/`). NodePort **`30191`** on the dev control plane; in-cluster: `http://layer-mcp-github-v1:8000/v1/mcp`. Tool `ask_repo` queries allowlisted GitHub repos and synthesizes answers via the inference gateway (`POST /v1/chat/completions` on **layer-gateway-inference**).

Omit `repo` → all repos in upstream [`app/allowlist/repos.py`](https://github.com/taixingbi/layer-mcp-github-v1/blob/main/app/allowlist/repos.py). `ask_repo_stream` is an alias for `ask_repo` with `stream: true`.

Key endpoints:

- `GET /health` — liveness
- `GET /version` — build info (`[project].version` in upstream `pyproject.toml`)
- `GET /ready` — readiness (env + upstream checks)
- `GET /metrics` — Prometheus
- `POST /v1/mcp` — MCP JSON-RPC / SSE

Upstream: [schema.md](https://github.com/taixingbi/layer-mcp-github-v1/blob/main/docs/schema.md), [design.md](https://github.com/taixingbi/layer-mcp-github-v1/blob/main/docs/design.md), [smoke-test.md](https://github.com/taixingbi/layer-mcp-github-v1/blob/main/docs/smoke-test.md). Smoke curls below adapt `127.0.0.1:8000` → `192.168.86.179:30191`.

**`latency_ms` (tool-native):** `ask_repo` / SSE `done` use **flat** keys — `github_readme`, `github_search`, `chat`, `follow_up_chat`, `total`. That is correct for this MCP service. When the same tool is invoked via [orchestrator](deploy-orchestrator.md) **`github_repo_search`**, those timings appear under **`latency_ms.github`** on the orchestrator response, with **`latency_ms.total`** and **`latency_ms.intent_router`** at the orchestrator level (see [schema-request-response.md](https://github.com/taixingbi/layer-orchestrator-v1/blob/main/docs/schema-request-response.md)).

## Prerequisites

- **layer-gateway-inference** in `ai-dev` (`http://layer-gateway-inference:8000` or NodePort `30180`); see [deploy-gateway-inference.md](deploy-gateway-inference.md).
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

Non-secret env is in [manifests/tool/layer-mcp-github-v1-dev.yaml](../manifests/tool/layer-mcp-github-v1-dev.yaml). Full list: upstream [`.env.example`](https://github.com/taixingbi/layer-mcp-github-v1/blob/main/.env.example).

| Variable | Dev value |
|----------|-----------|
| `GITHUB_OWNER` | `taixingbi` |
| `LLM_GATEWAY_BASE_URL` | `http://layer-gateway-inference:8000` |
| `LLM_MODEL` | `Qwen/Qwen2.5-7B-Instruct` |

Allowlisted repo short names are baked into the image ([`app/allowlist/repos.py`](https://github.com/taixingbi/layer-mcp-github-v1/blob/main/app/allowlist/repos.py)); expect **11** repos including `layer-orchestrator-v1`, `layer-mcp-github-v1`, and `k3s`.

## 2) Apply manifests

```bash
# optional: preload image on the node
sudo k3s ctr images pull docker.io/taixingbi/layer-mcp-github-v1:latest

# optional: remove legacy deployment (pre-v1 rename)
sudo k3s kubectl delete deployment,service layer-mcp-github -n ai-dev --ignore-not-found

sudo k3s kubectl apply -f manifests/tool/layer-mcp-github-v1-dev.yaml
sudo k3s kubectl rollout restart deployment/layer-mcp-github-v1 -n ai-dev
sudo k3s kubectl rollout status deployment/layer-mcp-github-v1 -n ai-dev
sudo k3s kubectl get pods,svc -n ai-dev -l app=layer-mcp-github-v1 -o wide
sudo k3s kubectl get svc -A -o wide | grep 30191
```

If the pod does not start:

```bash
sudo k3s kubectl describe pod -n ai-dev -l app=layer-mcp-github-v1
sudo k3s kubectl logs -n ai-dev deploy/layer-mcp-github-v1 --tail=50
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

**Pass:** `ask_repo`, `ask_repo_stream`. Use `/v1/mcp` not `/v1/mcp/`.

### 3.2 MCP — buffered (`stream: false`)

```bash
curl -sS --max-time 120 -X POST \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -d '{"jsonrpc":"2.0","id":"smoke-1","method":"tools/call","params":{"name":"ask_repo","arguments":{"repo":"layer-orchestrator-v1","question":"introduce this huntAi project","stream":false,"conversation_id":"conv_smoke_1","request_id":"req-smoke-1","session_id":"ses-smoke-1","trace_id":"trc-smoke-1"}}}' \
  http://192.168.86.179:30191/v1/mcp | jq '.result.structuredContent | {ok, answer, citations}'
```

**Pass:** `ok: true`, non-empty `answer` and `citations`.

### 3.3 MCP — SSE stream (`Accept: text/event-stream` + `stream: true`)

Requires `Accept: text/event-stream` and `"stream": true` on `ask_repo`. Events: `meta`, `status`, `delta`, `done`.

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
      "name":"ask_repo",
      "arguments":{
        "repo":"layer-orchestrator-v1",
        "question":"introduce this huntAi project",
        "stream":true,
        "conversation_id":"conv_smoke_1s"
      }
    }
  }' | tee /tmp/mcp-stream.txt
```

**Pass:** SSE lines with `event: meta`, `event: delta`, `event: done`; `meta` includes `request_id` `req-mcp-stream-1`.

**Final JSON from `done`:**

```bash
awk '/^event: done$/{p=1} p&&/^data: /{sub(/^data: /,""); print}' /tmp/mcp-stream.txt | tail -1 | jq '{ok, answer: (.answer|length), citations: (.citations|length)}'
```

### 3.4 MCP — correlation (`trace_id` optional)

```bash
curl -sS -X POST \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -d '{"jsonrpc":"2.0","id":"smoke-corr","method":"tools/call","params":{"name":"ask_repo","arguments":{"repo":"layer-orchestrator-v1","question":"One sentence.","stream":false}}}' \
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

Omits `repo` → all allowlisted repos under `GITHUB_OWNER`:

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
      "name":"ask_repo",
      "arguments":{
        "question":"introduce this huntAi project",
        "stream":true,
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
| 5 | `tools/list` on `/v1/mcp` | `ask_repo`, `ask_repo_stream` |
| 6 | `ask_repo` buffered | `ok: true`, answer + citations |
| 7 | `ask_repo` SSE | `meta` → optional `status` → `delta` (…) → `done` |
| 8 | correlation | ids present; `trace_id` null when omitted |
| 9 | `30180` `/v1/chat/completions` | `has_choices: true` |
| 10 | all repos (optional) | `repos` length = allowlist count |

During §3.2–3.3, pod logs should show GitHub readme/search and `POST .../v1/chat/completions` → `200 OK`. §3.3 SSE uses `/v1/mcp` (not a JSON-RPC envelope on the wire).

```bash
sudo k3s kubectl logs -n ai-dev deploy/layer-mcp-github-v1 -f --tail=30
```

## 4) Cursor / MCP clients

The container runs **HTTP MCP** (`python -m app.main --http`), not stdio. Point clients at:

- LAN: `http://192.168.86.179:30191/v1/mcp`
- Port-forward: `sudo k3s kubectl port-forward -n ai-dev svc/layer-mcp-github-v1 8000:8000` → `http://127.0.0.1:8000/v1/mcp`

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
| Stale MCP behavior | `rollout restart deployment/layer-mcp-github-v1 -n ai-dev` |

NodePort:

- dev: `30191`
