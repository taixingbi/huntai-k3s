# Deploy Gateway (dev/prod)

Gateway image: [taixingbi/layer-gateway-inference-v1](https://hub.docker.com/r/taixingbi/layer-gateway-inference-v1)

In-cluster: `http://layer-gateway-inference:8000` (dev `ai-dev`, prod `ai-prod`). LAN NodePorts: `30180` (dev), `30380` (prod); see `docs/port.md`.

## 1) Create secrets (required for `envFrom.secretRef`)

Both manifests use `envFrom.secretRef.name=layer-gateway-inference-secrets`.
Create the Secret in each namespace you deploy to.

```bash
mkdir -p ~/.secrets
chmod 700 ~/.secrets
printf '%s' 'sk-xxxxx' > ~/.secrets/openai.key
chmod 600 ~/.secrets/openai.key

# dev
sudo k3s kubectl create secret generic layer-gateway-inference-secrets -n ai-dev \
  --from-file=OPENAI_API_KEY="$HOME/.secrets/openai.key" \
  --dry-run=client -o yaml | sudo k3s kubectl apply -f -

# prod
sudo k3s kubectl create secret generic layer-gateway-inference-secrets -n ai-prod \
  --from-file=OPENAI_API_KEY="$HOME/.secrets/openai.key" \
  --dry-run=client -o yaml | sudo k3s kubectl apply -f -

# check config
sudo k3s kubectl -n ai-dev exec -it deploy/layer-gateway-inference -- cat /app/config.yaml
sudo k3s kubectl -n ai-prod exec -it deploy/layer-gateway-inference -- cat /app/config.yaml

# check secret
sudo k3s kubectl get secret layer-gateway-inference-secrets -n ai-dev \
  -o jsonpath='{.data.OPENAI_API_KEY}' | base64 -d | wc -c

sudo k3s kubectl get secret layer-gateway-inference-secrets -n ai-prod
  -o jsonpath='{.data.OPENAI_API_KEY}' | base64 -d | wc -c
```

## 2) Apply manifests

```bash
# dev
sudo k3s kubectl apply -f manifests/gateway/layer-gateway-inference-dev.yaml # deploy layer-gateway-inference-dev.yaml
sudo k3s kubectl rollout restart deployment/layer-gateway-inference -n ai-dev # pull image
sudo k3s kubectl get pods,svc -n ai-dev -l app=layer-gateway-inference
sudo k3s kubectl get svc -A -o wide | grep 30180
sudo k3s kubectl get pods -n ai-dev -l app=layer-gateway-inference -o wide
# prod
sudo k3s kubectl rollout restart deployment/layer-gateway-inference -n ai-prod
sudo k3s kubectl apply -f manifests/gateway/layer-gateway-inference-prod.yaml
sudo k3s kubectl get pods,svc -n ai-prod -l app=layer-gateway-inference
sudo k3s kubectl get svc -A -o wide | grep 30380
sudo k3s kubectl get pods -n ai-prod -l app=layer-gateway-inference -o wide
```

NodePorts:

- dev: `30180`
- prod: `30380`

