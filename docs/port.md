Gateway and RAG workloads listen on **8000** inside the cluster (Service `port`); below are **NodePort** values on the node.

30080 → inference (vLLM) 
30081 → embedding(vLLM) 
30082 → reranker(vLLM) 

30180 → gateway-inference (dev) 
30280 → gateway-inference (qa) 
30380 → gateway-inference (prod) 

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

30185 → gateway-api (dev)
30285 → gateway-api (qa)
30385 → gateway-api (prod)