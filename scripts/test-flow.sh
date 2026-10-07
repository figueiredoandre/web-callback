#!/usr/bin/env bash
# Testa o fluxo da Ponte: cenários negativos (sem credencial) + ida + volta + anti-replay.
# Uso:
#   ./scripts/test-flow.sh                                   # só testes sem credencial
#   SERVICE_TOKEN='<bearer>' TENANT='<tenant>' ./scripts/test-flow.sh
#   BASE_URL=https://wcb.exemplo.com.br/iwlcb ./scripts/test-flow.sh   # via proxy HTTPS
#   CURL_OPTS=-k BASE_URL=https://localhost/iwlcb ./scripts/test-flow.sh  # cert não confere com o nome
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; [[ -f .env ]] && . ./.env; set +a
BASE="${BASE_URL:-http://localhost:${HOST_HTTP_PORT:-8080}/iwlcb}"
PREFIX="${BRIDGE_TRANSACTION_KEY_PREFIX:-iwlcb:txn:}"
RETURN_URI="${RETURN_URI:-https://app.example.com/return}"
FAIL=0
check(){ # $1=descrição $2=esperado $3=obtido
  if [[ "$3" == "$2" ]]; then echo "  [OK]    $1 -> $3"; else echo "  [FALHA] $1 -> esperado $2, obtido $3"; FAIL=1; fi; }
rcli(){ docker exec wcb-redis redis-cli --no-auth-warning -a "$REDIS_PASSWORD" "$@" 2>/dev/null; }
code(){ curl ${CURL_OPTS:-} -s -o /dev/null -w '%{http_code}' "$@"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
openssl genrsa -out "$TMP/priv.pem" 2048 2>/dev/null
N="$(openssl rsa -in "$TMP/priv.pem" -noout -modulus | cut -d= -f2 | xxd -r -p | base64 -w0 | tr '+/' '-_' | tr -d '=')"
BODY=$(printf '{"redirect_uri":"%s","public_key":{"kty":"RSA","n":"%s","e":"AQAB"},"tenant":"%s"}' "$RETURN_URI" "$N" "${TENANT:-tenant-teste}")

echo "== A) Testes sem credencial =="
check "GET  /health"                                   200 "$(code "$BASE/health")"
# A app valida o formato do body ANTES da credencial: body inválido -> 400 (ok, não é falha)
check "POST body vazio '{}'"                           400 "$(code -X POST "$BASE/transactions/v1" -H 'Content-Type: application/json' -d '{}')"
check "POST body válido sem Authorization"             401 "$(code -X POST "$BASE/transactions/v1" -H 'Content-Type: application/json' -d "$BODY")"
# Token falso obriga a app a consultar o user-info da plataforma:
#   401 = plataforma alcançada e rejeitou (saída HTTPS OK) | 503 = container NÃO alcança a plataforma
R="$(code -X POST "$BASE/transactions/v1" -H 'Authorization: Bearer token-invalido' -H 'Content-Type: application/json' -d "$BODY")"
check "POST com token falso (testa saída p/ plataforma)" 401 "$R"
[[ "$R" == 503 ]] && echo "          -> 503: sem acesso HTTPS à plataforma Senior a partir do container (firewall/proxy/DNS)"
check "GET  /redirect/v1 com state inexistente"        400 "$(code "$BASE/redirect/v1?state=00000000-0000-4000-8000-000000000000&code=x")"
check "GET  /redirect/v1 sem parâmetros"               400 "$(code "$BASE/redirect/v1")"

if [[ -z "${SERVICE_TOKEN:-}" || -z "${TENANT:-}" ]]; then
  echo; echo "Defina SERVICE_TOKEN e TENANT para testar ida/volta."; exit $FAIL
fi

echo "== B) Ida: POST /transactions/v1 =="
HTTP="$(curl ${CURL_OPTS:-} -s -o "$TMP/ida.json" -D "$TMP/ida.h" -w '%{http_code}' -X POST "$BASE/transactions/v1" \
  -H "Authorization: Bearer ${SERVICE_TOKEN}" -H 'Content-Type: application/json' -d "$BODY")"
echo "     corpo: $(cat "$TMP/ida.json")"
check "ida" 201 "$HTTP"
[[ "$HTTP" == 201 ]] || { echo "  401=token inválido/ambiente diferente de BRIDGE_PLATFORM_ENV | 400=tenant divergente | 503=sem saída p/ plataforma"; exit 1; }
TXN="$(sed -E 's/.*"transaction_id":"([^"]+)".*/\1/' "$TMP/ida.json")"
echo "     Location: $(grep -i '^location:' "$TMP/ida.h" | tr -d '\r' | cut -d' ' -f2-)"
echo "     Redis: ${PREFIX}${TXN} existe=$(rcli exists "${PREFIX}${TXN}") TTL=$(rcli ttl "${PREFIX}${TXN}")s"

echo "== C) Volta: GET /redirect/v1 (simulando o Keycloak) =="
HTTP="$(curl ${CURL_OPTS:-} -s -o /dev/null -D "$TMP/volta.h" -w '%{http_code}' "$BASE/redirect/v1?state=${TXN}&code=codigo-de-teste-123")"
check "volta" 302 "$HTTP"
LOC="$(grep -i '^location:' "$TMP/volta.h" | tr -d '\r' | cut -d' ' -f2-)"
echo "     Location: ${LOC:0:160}..."
[[ "$LOC" == "$RETURN_URI"* ]] && echo "  [OK]    redireciona para o return_uri" || { echo "  [FALHA] Location não começa com $RETURN_URI"; FAIL=1; }
[[ "$LOC" != *"codigo-de-teste-123"* ]] && echo "  [OK]    code não aparece em claro (cifrado)" || { echo "  [FALHA] code em claro!"; FAIL=1; }
check "transação removida do Redis após consumo" 0 "$(rcli exists "${PREFIX}${TXN}")"

echo "== D) Anti-replay =="
check "reutilizar o mesmo state" 400 "$(code "$BASE/redirect/v1?state=${TXN}&code=codigo-de-teste-123")"

echo; [[ $FAIL -eq 0 ]] && echo "RESULTADO: OK" || { echo "RESULTADO: FALHAS"; exit 1; }
