#!/usr/bin/env bash
# Baixa o WAR publicado no Nexus e valida o checksum SHA-1 publicado ao lado.
# Uso:
#   ./scripts/download-war.sh                 # versão 1.0.0, Nexus anônimo
#   NEXUS_USER=fulano ./scripts/download-war.sh   # pede a senha (não fica no histórico)
set -euo pipefail

VERSION="${APP_VERSION:-1.0.0}"
BASE="https://nexus.senior.com.br/repository/libs-release-local/br/com/senior/xt/idp/web-callback"
URL="${BASE}/${VERSION}/web-callback-${VERSION}.war"
DEST_DIR="$(cd "$(dirname "$0")/.." && pwd)/artifacts"
DEST="${DEST_DIR}/web-callback-${VERSION}.war"

mkdir -p "$DEST_DIR"

AUTH=()
if [[ -n "${NEXUS_USER:-}" ]]; then
  read -rsp "Senha Nexus para ${NEXUS_USER}: " NEXUS_PASS; echo
  AUTH=(--user "${NEXUS_USER}:${NEXUS_PASS}")
fi

echo ">> Baixando ${URL}"
curl -fSL "${AUTH[@]}" -o "$DEST" "$URL"

echo ">> Validando SHA-1"
EXPECTED="$(curl -fsSL "${AUTH[@]}" "${URL}.sha1" | awk '{print $1}')"
ACTUAL="$(sha1sum "$DEST" | awk '{print $1}')"
if [[ "$EXPECTED" != "$ACTUAL" ]]; then
  echo "!! Checksum divergente (esperado=$EXPECTED obtido=$ACTUAL)"; rm -f "$DEST"; exit 1
fi
echo "   OK ($ACTUAL)"

echo ">> Conferindo conteúdo do WAR"
unzip -l "$DEST" | grep -E "WEB-INF/(web.xml|lib/(jedis|nimbus|bcprov|bcpkix|logback))" || true
if command -v jarsigner >/dev/null 2>&1; then
  jarsigner -verify "$DEST" | tail -n1
fi
echo ">> WAR pronto em: $DEST"
