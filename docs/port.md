Gateway and RAG workloads listen on **8000** inside the cluster (Service `port`); below are **NodePort** values on the node. **layer-web** (Next.js) uses Service port **3000** (NodePort `30186` dev).

**Dev** rows are deployed via Argo CD. **qa** / **prod** rows are **reserved** (no overlays yet).

30080 → inference / chat (vLLM bundle NodePort)
30081 → embedding (vLLM) — in-cluster `vllm-embed-gpu-node-*:8001` (no NodePort)
30082 → reranker (vLLM) — in-cluster `vllm-rerank-gpu-node-*:8002` (no NodePort)

30180 → gateway-inference (dev) 
30280 → gateway-inference (qa) — reserved
30380 → gateway-inference (prod) — reserved, not deployed

30181 → gateway-embedding (dev) 
30281 → gateway-embedding (qa) — reserved
30381 → gateway-embedding (prod) — reserved

30182 → gateway-reranker (dev) 
30282 → gateway-reranker (qa) — reserved
30382 → gateway-reranker (prod) — reserved

30183 → rag-query (dev) 
30283 → rag-query (qa) — reserved
30383 → rag-query (prod) — reserved

30184 → orchestrator (dev)
30284 → orchestrator (qa) — reserved
30384 → orchestrator (prod) — reserved

30185 → layer-gateway-api-v1 (dev)
30285 → gateway-api (qa) — reserved
30385 → gateway-api (prod) — reserved

30186 → layer-web (dev)
30286 → layer-web (qa) — reserved
30386 → layer-web (prod) — reserved

6333 → qdrant (dev, in-cluster ClusterIP; no NodePort)

# Tools / MCP (pod :8000 unless noted)
30187-30190 → reserved (future tools, dev)
30191 → layer-mcp-github-v1 (dev)
30287-30290 → reserved (future tools, qa)
30291 → layer-mcp-github-v1 (qa) — reserved
30387-30390 → reserved (future tools, prod)
30391 → layer-mcp-github-v1 (prod) — reserved
