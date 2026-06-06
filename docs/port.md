# Ports and cluster endpoints

## Hosts (LAN)

| Host | Role | IP |
|------|------|-----|
| `server-node-1` | k3s control plane | `192.168.86.179` |
| `gpu-node-1` | GPU worker | `192.168.86.173` |
| `gpu-node-2` | GPU worker | `192.168.86.176` |

**Smoke tests from `server-node-1`:** prefer **ClusterIP** or in-cluster DNS for gateways (NodePort to this node's own LAN IP can hang — hairpin). From a laptop, use `192.168.86.179:<NodePort>` below.

**Prometheus UI (local TSDB):** port-forward `monitoring/prometheus:9090` or NodePort if exposed — see [deploy-prometheus.md](deploy-prometheus.md).

## NodePorts (dev)

Gateway and RAG workloads listen on **8000** inside the cluster (Service `port`); below are **NodePort** values on the control plane unless noted. **layer-web** (Next.js) uses Service port **3000** (NodePort `30186` dev).

**Dev** rows are deployed via Argo CD. **Prod** user stack (`ai-prod`): gateway-api, orchestrator, rag, web — see [deploy-prod.md](deploy-prod.md). **qa** ports remain reserved.

| Port | Service | URL hint (dev) |
|------|---------|----------------|
| 30080 | vLLM chat (per-node NodePort on GPU hosts) | `http://192.168.86.173:30080`, `http://192.168.86.176:30080` |
| 30081 | vLLM embed (GPU hosts) | `:30081` on GPU node IPs |
| 30082 | vLLM rerank (GPU hosts) | `:30082` on GPU node IPs |
| 30180 | gateway-inference | `http://192.168.86.179:30180` |
| 30181 | gateway-embedding | `http://192.168.86.179:30181` |
| 30182 | gateway-reranker | `http://192.168.86.179:30182` |
| 30183 | rag-query | `http://192.168.86.179:30183` |
| 30184 | orchestrator | `http://192.168.86.179:30184` |
| 30185 | gateway-api | `http://192.168.86.179:30185` |
| 30186 | layer-web | `http://192.168.86.179:30186` |
| 30191 | layer-mcp-github | `http://192.168.86.179:30191` |

SSE event names differ by service — see [sse-streaming-events.md](sse-streaming-events.md).
| 30633 | qdrant | `http://192.168.86.179:30633` (in-cluster `qdrant:6333`) |

| Port | Service (prod `ai-prod`) |
|------|--------------------------|
| 30383 | rag-query |
| 30384 | orchestrator |
| 30385 | gateway-api |
| 30386 | layer-web |
| 30391 | layer-mcp-github |

Reserved **qa** ports (30280–30291, etc.) — not deployed.

## In-cluster DNS (gateways → vLLM)

See [architecture.md](architecture.md).

| Backend | URL |
|---------|-----|
| Chat | `http://vllm-chat-gpu-node-{1,2}.vllm.svc.cluster.local:8000` |
| Embed | `http://vllm-embed-gpu-node-{1,2}.vllm.svc.cluster.local:8001` |
| Rerank | `http://vllm-rerank-gpu-node-{1,2}.vllm.svc.cluster.local:8002` |
