Gateway and RAG workloads listen on **8000** inside the cluster (Service `port`); below are **NodePort** values on the node. **layer-web** (Next.js) uses Service port **3000** (NodePort `30186` dev).

30080 → inference (vLLM) 
30081 → embedding(vLLM) 
30082 → reranker(vLLM) 

30180 → gateway-inference (dev) 
30280 → gateway-inference (qa) 
30380 → reserved (gateway-inference prod, not deployed)

30181 → gateway-embedding (dev) 
30281 → gateway-embedding (qa) 
30381 → gateway-embedding (prod) 

30182 → gateway-reranker (dev) 
30282 → gateway-reranker (qa) 
30382 → gateway-reranker (prod)

30183 → rag-query (dev) 
30283 → rag-query (qa) 
30383 → rag-query (prod)

30184 → orchestrator (dev)
30284 → orchestrator (qa)
30384 → orchestrator (prod)

30185 → layer-gateway-api-v1 (dev)
30285 → gateway-api (qa)
30385 → gateway-api (prod)

30186 → layer-web (dev)
30286 → layer-web (qa)
30386 → layer-web (prod)

# Tools / MCP (pod :8000 unless noted)
30187-30190 → reserved (future tools, dev)
30191 → layer-mcp-github-v1 (dev)
30287-30290 → reserved (future tools, qa)
30291 → layer-mcp-github-v1 (qa)
30387-30390 → reserved (future tools, prod)
30391 → layer-mcp-github-v1 (prod)