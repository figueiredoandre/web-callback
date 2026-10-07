#!/usr/bin/env bash
# Gera CA + certificado do Redis (SAN=redis) e um truststore Java para validar
# REDIS_SSL=true no ambiente de VALIDAÇÃO. Em produção o Redis é da infra e o
# certificado vem da CA corporativa.
#
# IMPORTANTE: o truststore é uma CÓPIA do cacerts do JDK + a CA local. Se apontar
# javax.net.ssl.trustStore só para a CA local, a JVM deixa de confiar nas CAs
# públicas e a chamada HTTPS à plataforma Senior (user-info) quebra.
set -euo pipefail
cd "$(dirname "$0")"
TOMCAT_IMAGE="${TOMCAT_IMAGE:-tomcat:10.1-jdk25-temurin}"
mkdir -p certs && cd certs

openssl req -x509 -newkey rsa:3072 -nodes -days 365 -subj "/CN=wcb-validation-ca" \
  -keyout ca.key -out ca.crt
openssl req -newkey rsa:2048 -nodes -subj "/CN=redis" -keyout redis.key -out redis.csr
printf "subjectAltName=DNS:redis,DNS:wcb-redis,DNS:localhost\nextendedKeyUsage=serverAuth\n" > ext.cnf
openssl x509 -req -in redis.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 365 \
  -extfile ext.cnf -out redis.crt
rm -f redis.csr ext.cnf ca.srl

docker run --rm --user "$(id -u):$(id -g)" -v "$PWD:/certs" "$TOMCAT_IMAGE" bash -c '
  cp "$JAVA_HOME/lib/security/cacerts" /certs/truststore.p12 && chmod u+w /certs/truststore.p12 &&
  keytool -importcert -noprompt -alias wcb-redis-ca -file /certs/ca.crt \
          -keystore /certs/truststore.p12 -storetype PKCS12 -storepass changeit'

# Somente validação: leitura para os UIDs dos containers (redis=999, app=10001)
chmod 644 redis.crt redis.key ca.crt truststore.p12
chmod 600 ca.key
echo "Certificados gerados em tls/certs/"
