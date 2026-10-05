#!/usr/bin/env bash
# Testa a API de ponta a ponta. Uso:
#   ./scripts/smoke-test.sh                                          # docker compose (porta 3000)
#   BASE_URL=http://localhost SKIP_INTERNAL=1 ./scripts/smoke-test.sh   # Kubernetes via Ingress
set -uo pipefail
BASE_URL="${BASE_URL:-http://localhost:3000}"
SKIP_INTERNAL="${SKIP_INTERNAL:-0}"   # 1 = não testa /health, /ready, /metrics (não expostos pelo Ingress)
fail=0
check() { if [ "$2" = "$3" ]; then echo "  ✔ $1 ($3)"; else echo "  ✘ $1 (esperado $2, obtido $3)"; fail=1; fi; }
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
JSON='Content-Type: application/json'

echo "== Contratos ($BASE_URL)"
if [ "$SKIP_INTERNAL" != "1" ]; then
  check "GET /health" 200 "$(code "$BASE_URL/health")"
  check "GET /ready"  200 "$(code "$BASE_URL/ready")"
fi
check "POST /contracts sem campos obrigatórios" 400 "$(code -X POST "$BASE_URL/contracts" -H "$JSON" -d '{}')"
check "POST /contracts válido" 201 \
  "$(code -X POST "$BASE_URL/contracts" -H "$JSON" \
      -d '{"title":"Contrato de teste","userId":"user-1","description":"smoke test","value":1500.50}')"
[ "$SKIP_INTERNAL" != "1" ] && check "GET /metrics" 200 "$(code "$BASE_URL/metrics")"

echo
if [ "$fail" = 0 ]; then echo "Todos os testes passaram."; else echo "Há testes falhando."; fi
exit "$fail"
