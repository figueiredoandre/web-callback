#!/usr/bin/env bash
# Valida o HTTPS do proxy e o hardening do Tomcat.
# Uso (no servidor):
#   DOMAIN=wcb.exemplo.com.br ./scripts/check-https.sh     # cert emitido para esse nome
#   ./scripts/check-https.sh                                # sem DOMAIN: usa localhost e ignora validação do cert
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; [[ -f .env ]] && . ./.env; set +a
CERT_DIR="${TLS_CERT_DIR:-./certs}"
PORT="${HOST_HTTPS_PORT:-443}"; HPORT="${HOST_HTTP_PORT_PUBLIC:-80}"
FAIL=0
ok(){ echo "  [OK]    $*"; }
ko(){ echo "  [FALHA] $*"; FAIL=1; }

# Os testes de comportamento usam -k (independem da cadeia); a validação do certificado
# é feita à parte na seção 2, para separar "TLS quebrado" de "cadeia incompleta".
if [[ -n "${DOMAIN:-}" ]]; then
  H="$DOMAIN"
  # --resolve: testa no próprio servidor com SNI real, sem depender do DNS
  C=(curl -s -k --resolve "$DOMAIN:$PORT:127.0.0.1" --resolve "$DOMAIN:$HPORT:127.0.0.1")
else
  H="localhost"; C=(curl -s -k); echo "(DOMAIN não definido: nome do certificado NÃO será validado)"
fi
URL="https://$H:$PORT"

echo "== 1) Arquivos do certificado ($CERT_DIR) =="
if [[ -f "$CERT_DIR/tls.crt" && -f "$CERT_DIR/tls.key" ]]; then
  ok "tls.crt e tls.key presentes"
  KH="$(head -n1 "$CERT_DIR/tls.key" | tr -d '\r')"
  case "$KH" in
    *"BEGIN PRIVATE KEY"*|*"BEGIN RSA PRIVATE KEY"*|*"BEGIN EC PRIVATE KEY"*) ok "tls.key é chave privada PEM ($KH)";;
    *"ENCRYPTED PRIVATE KEY"*|*"Proc-Type: 4,ENCRYPTED"*) ko "tls.key tem senha: openssl pkey -in tls.key -out tls.key.nova";;
    *"BEGIN CERTIFICATE"*) ko "tls.key contém um CERTIFICADO, não a chave privada ($KH)";;
    *) ko "tls.key não é PEM reconhecido: '$KH' (PFX/DER? veja README)";;
  esac
  cmp -s "$CERT_DIR/tls.crt" "$CERT_DIR/tls.key" && ko "tls.key é idêntico ao tls.crt (copiou o certificado no lugar da chave)"
  A="$(openssl x509 -in "$CERT_DIR/tls.crt" -noout -pubkey | openssl sha256)"
  B="$(openssl pkey -in "$CERT_DIR/tls.key" -pubout 2>/dev/null | openssl sha256)"
  [[ "$A" == "$B" ]] && ok "chave privada corresponde ao certificado" || ko "tls.key NÃO corresponde ao tls.crt"
  echo "          $(openssl x509 -in "$CERT_DIR/tls.crt" -noout -subject)"
  echo "          $(openssl x509 -in "$CERT_DIR/tls.crt" -noout -ext subjectAltName 2>/dev/null | tail -n1 | sed 's/^ *//')"
  echo "          expira: $(openssl x509 -in "$CERT_DIR/tls.crt" -noout -enddate | cut -d= -f2)"
  openssl x509 -in "$CERT_DIR/tls.crt" -noout -checkend 2592000 >/dev/null && ok "válido por mais de 30 dias" || ko "expira em menos de 30 dias"
  N="$(grep -c 'BEGIN CERTIFICATE' "$CERT_DIR/tls.crt")"
  [[ "$N" -ge 2 ]] && ok "tls.crt contém cadeia ($N certificados)" || echo "  [AVISO] tls.crt tem 1 certificado: inclua as intermediárias (senão clientes podem falhar)"
else
  ko "faltam $CERT_DIR/tls.crt e/ou tls.key"
fi

echo "== 2) Proxy / TLS =="
if [[ -n "${DOMAIN:-}" ]]; then
  VERR="$(curl -s -o /dev/null --resolve "$DOMAIN:$PORT:127.0.0.1" "https://$DOMAIN:$PORT/nginx-health" 2>&1; echo "exit=$?")"
  if [[ "$VERR" == *"exit=0"* ]]; then ok "certificado validado para $DOMAIN (nome + cadeia)"
  elif [[ "$VERR" == *"exit=60"* ]]; then echo "  [AVISO] cadeia não validada (falta intermediária): navegadores podem aceitar; curl/Java/clientes servidor-a-servidor recusam"
  elif [[ "$VERR" == *"exit=7"* ]]; then ko "porta $PORT não responde (proxy no ar? docker logs wcb-proxy)"
  else ko "falha TLS/nome ($VERR)"; fi
fi
R="$("${C[@]}" -o /dev/null -w '%{http_code} %{redirect_url}' "http://$H:$HPORT/iwlcb/health")"
[[ "$R" == 301\ https://* ]] && ok "HTTP redireciona para HTTPS ($R)" || ko "HTTP -> esperado 301 https, obtido: $R"
BF="$(mktemp)"; HDR="$("${C[@]}" -D - -o "$BF" "$URL/iwlcb/health")"; BODY="$(cat "$BF")"; rm -f "$BF"
echo "$HDR" | head -n1 | grep -q " 200" && ok "HTTPS /iwlcb/health 200" || ko "HTTPS /iwlcb/health não respondeu 200 (proxy no ar? docker logs wcb-proxy)"
[[ "$BODY" == '{"status":"UP"}' ]] && ok "health sem build-info: $BODY" || ko "health expõe dados: $BODY (BRIDGE_HEALTH_VERBOSE=false?)"
echo "$HDR" | grep -qi '^x-app-version' && ko "header X-App-Version presente" || ok "sem X-App-Version"
echo "$HDR" | grep -qi '^strict-transport-security' && ok "HSTS presente" || ko "HSTS ausente"
SRV="$(echo "$HDR" | grep -i '^server:' | tr -d '\r')"
[[ "$SRV" =~ [0-9] ]] && ko "Server expõe versão: $SRV" || ok "Server sem versão (${SRV:-ausente})"
for v in tls1 tls1_1; do
  if echo | openssl s_client -connect "127.0.0.1:$PORT" -servername "$H" -"$v" >/dev/null 2>&1; then ko "aceita $v"; else ok "recusa $v"; fi
done
echo | openssl s_client -connect "127.0.0.1:$PORT" -servername "$H" -tls1_3 >/dev/null 2>&1 && ok "aceita TLS 1.3" || echo "  [AVISO] TLS 1.3 não negociado"

echo "== 3) Sem exposição de versão em erros =="
for p in /naoexiste /iwlcb/naoexiste /manager/html /iwlcb/WEB-INF/web.xml "/iwlcb/%2e%2e/manager/html"; do
  RESP="$("${C[@]}" -w ' HTTP=%{http_code}' "$URL$p")"
  CODE="${RESP##*HTTP=}"
  if echo "$RESP" | grep -Eqi 'tomcat|apache|nginx/[0-9]|exception'; then ko "$p -> $CODE expõe servidor/versão"; 
  elif [[ "$CODE" =~ ^(400|403|404)$ ]]; then ok "$p -> $CODE neutro"; else ko "$p -> $CODE inesperado"; fi
done
R="$("${C[@]}" -o /dev/null -w '%{http_code}' -X TRACE "$URL/iwlcb/health")"
[[ "$R" =~ ^(403|405)$ ]] && ok "TRACE bloqueado ($R)" || ko "TRACE -> $R"
R="$(curl -s "http://127.0.0.1:${HOST_HTTP_PORT:-8080}/naoexiste")"
echo "$R" | grep -qi 'tomcat' && ko "Tomcat direto (8080) ainda mostra versão" || ok "Tomcat direto (8080): 404 sem versão"

echo "== 4) Runtime do container =="
docker exec wcb-app bash -c 'touch /usr/local/tomcat/webapps/iwlcb/x' 2>/dev/null && ko "app gravável" || ok "aplicação somente-leitura"
docker exec wcb-app bash -c 'exec 3<>/dev/tcp/127.0.0.1/8005' 2>/dev/null && ko "porta de shutdown 8005 aberta" || ok "porta de shutdown 8005 desativada"
[[ "$(docker exec wcb-app id -u)" != 0 ]] && ok "Tomcat roda como UID $(docker exec wcb-app id -u)" || ko "Tomcat roda como root"
docker exec wcb-app bash -c 'command -v javac' >/dev/null 2>&1 && echo "  [AVISO] imagem com JDK (javac presente) — RUNTIME_IMAGE JRE recomendada" || ok "runtime sem javac (JRE)"
docker port wcb-app 2>/dev/null | grep -v '127.0.0.1' | grep -q . && ko "Tomcat publicado fora do localhost: $(docker port wcb-app)" || ok "Tomcat só em 127.0.0.1"

echo; [[ $FAIL -eq 0 ]] && echo "RESULTADO: OK" || { echo "RESULTADO: FALHAS"; exit 1; }
