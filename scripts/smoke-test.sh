#!/usr/bin/env bash
# Validação da Fase 1: containers, Redis, health e (opcional) fluxo de ida.
# Uso:
#   ./scripts/smoke-test.sh
#   SERVICE_TOKEN='<bearer>' TENANT='minha-empresa' ./scripts/smoke-test.sh   # testa também a ida
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; [[ -f .env ]] && . ./.env; set +a

BASE="http://localhost:${HOST_HTTP_PORT:-8080}/iwlcb"
PREFIX="${BRIDGE_TRANSACTION_KEY_PREFIX:-iwlcb:txn:}"
ok(){ echo "  [OK]  $*"; }
ko(){ echo "  [FALHA] $*"; FAIL=1; }
FAIL=0
TLSARGS=()
docker exec wcb-redis test -f /tls/ca.crt 2>/dev/null && TLSARGS=(--tls --cacert /tls/ca.crt)
rcli(){ docker exec wcb-redis redis-cli "${TLSARGS[@]}" --no-auth-warning -a "$REDIS_PASSWORD" "$@"; }

echo "1) Estado dos containers"
docker compose ps

echo "2) Redis"
[[ "$(rcli ping 2>/dev/null)" == "PONG" ]] && ok "PING -> PONG" || ko "Redis não responde"

echo "3) Rede app -> redis (DNS interno + porta)"
docker exec wcb-app bash -c 'exec 3<>/dev/tcp/redis/6379' 2>/dev/null \
  && ok "wcb-app alcança redis:6379" || ko "wcb-app NÃO alcança redis:6379"

echo "4) Deploy do WAR no Tomcat"
if docker logs wcb-app 2>&1 | grep -Eq "Deployment of web application (archive|directory) .*iwlcb.* has finished"; then
  ok "iwlcb implantado"
else
  ko "deploy não concluído - veja: docker logs wcb-app"
fi
docker logs wcb-app 2>&1 | grep -iE "SEVERE|Exception|Error" | tail -n 5

echo "5) Health"
RESP="$(curl -s -w ' HTTP=%{http_code}' "$BASE/health")"
echo "     $RESP"
[[ "$RESP" == *"HTTP=200"* && "$RESP" == *'"UP"'* ]] && ok "/health UP" || ko "/health não está UP"

echo "6) Healthcheck do Docker"
echo "     $(docker inspect -f '{{.State.Health.Status}}' wcb-app)"

if [[ -n "${SERVICE_TOKEN:-}" && -n "${TENANT:-}" ]]; then
  echo "7) Ida - POST /transactions/v1 (chave RSA descartável)"
  TMP="$(mktemp -d)"
  openssl genrsa -out "$TMP/k.pem" 2048 2>/dev/null
  N="$(openssl rsa -in "$TMP/k.pem" -noout -modulus | cut -d= -f2 | xxd -r -p | base64 -w0 | tr '+/' '-_' | tr -d '=')"
  BODY=$(printf '{"redirect_uri":"https://app.example.com/return","public_key":{"kty":"RSA","n":"%s","e":"AQAB"},"tenant":"%s"}' "$N" "$TENANT")
  RESP="$(curl -s -w ' HTTP=%{http_code}' -X POST "$BASE/transactions/v1" \
          -H "Authorization: Bearer ${SERVICE_TOKEN}" -H 'Content-Type: application/json' -d "$BODY")"
  echo "     $RESP"
  if [[ "$RESP" == *"HTTP=201"* ]]; then
    ok "transação criada"
    TXN="$(echo "$RESP" | sed -E 's/.*"transaction_id":"([^"]+)".*/\1/')"
    echo "     chave no Redis: ${PREFIX}${TXN} TTL=$(rcli ttl "${PREFIX}${TXN}")s"
    echo "     Para a volta: autentique no Keycloak com state=${TXN}; o callback chama"
    echo "     GET $BASE/redirect/v1?state=${TXN}&code=<code> -> 302 para o return_uri"
  else
    ko "ida não retornou 201 (401=credencial, 503=plataforma inacessível a partir do servidor)"
  fi
  rm -rf "$TMP"
fi

echo; [[ $FAIL -eq 0 ]] && echo "RESULTADO: OK" || { echo "RESULTADO: FALHAS ENCONTRADAS"; exit 1; }
