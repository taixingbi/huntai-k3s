#!/usr/bin/env bash
# Verify prod password-reset URL alignment (web APP_URL, gateway FRONTEND_URL, Supabase hints).
set -euo pipefail

KUBECTL="${KUBECTL:-sudo k3s kubectl}"
NS="${NS:-ai-prod}"

echo "== prod pod env =="
for deploy in layer-web layer-gateway-api; do
  echo "--- ${deploy} ---"
  $KUBECTL -n "$NS" exec "deploy/${deploy}" -- sh -c '
    echo "APP_URL=${APP_URL:-}"
    echo "FRONTEND_URL=${FRONTEND_URL:-}"
    echo "ADDITIONAL_FRONTEND_URLS=${ADDITIONAL_FRONTEND_URLS:-}"
    echo "ADDITIONAL_AUTH_REDIRECT_URLS=${ADDITIONAL_AUTH_REDIRECT_URLS:-}"
    echo "SUPABASE_URL=${SUPABASE_URL:+set}"
  ' 2>/dev/null || echo "(pod not ready)"
done

echo
echo "== web auth config (public) =="
curl -sS "http://192.168.86.179:30386/api/v1/auth/config" 2>/dev/null | python3 -m json.tool || \
  curl -sS "https://taixingai.com/api/v1/auth/config" 2>/dev/null | python3 -m json.tool || \
  echo "(curl failed — sync web-prod and check NodePort / tunnel)"

echo
echo "== gateway /ready =="
curl -sS "http://192.168.86.179:30385/ready" 2>/dev/null | python3 -m json.tool || echo "(curl failed)"

cat <<'EOF'

== Supabase prod project (manual — Dashboard → Authentication → URL configuration) ==

  Site URL:
    https://taixingai.com

  Redirect URLs (add each line):
    https://taixingai.com/auth/reset-password
    https://www.taixingai.com/auth/reset-password
    http://192.168.86.179:30386/auth/reset-password

After updating Supabase, request a NEW forgot-password email (old links stay invalid).

EOF
