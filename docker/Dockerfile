# syntax=docker/dockerfile:1
# -----------------------------------------------------------------------------
# Web Callback (Ponte OIDC) - br.com.senior.xt.idp:web-callback
# Runtime: Tomcat 10.1 (Servlet 6.0 / jakarta.*) + Java 25 (Temurin)
#
# Fase 2 (hardening):
#  - stage "explode": expande o WAR no build (runtime não precisa escrever em webapps/)
#  - runtime JRE (sem javac/jar/jshell). Se a tag JRE não existir no seu registry,
#    use RUNTIME_IMAGE=tomcat:10.1-jdk25-temurin (comportamento idêntico ao validado).
#  - server.xml enxuto + ErrorReportValve sem versão + logs só em stdout
#  - app e conf pertencem ao root (somente leitura para o usuário do Tomcat)
# Recomendado: fixar patch + digest, ex.: tomcat:10.1.60-jre25-temurin@sha256:...
# -----------------------------------------------------------------------------
ARG BUILD_IMAGE=tomcat:10.1-jdk25-temurin
ARG RUNTIME_IMAGE=tomcat:10.1-jre25-temurin

# ---------- stage 1: expandir o WAR -----------------------------------------
FROM ${BUILD_IMAGE} AS explode
ARG APP_VERSION=1.0.0
COPY artifacts/web-callback-${APP_VERSION}.war /tmp/app.war
RUN mkdir -p /out/iwlcb && cd /out/iwlcb && jar xf /tmp/app.war

# ---------- stage 2: runtime ------------------------------------------------
FROM ${RUNTIME_IMAGE}
ARG APP_VERSION=1.0.0
ARG IMAGE_REVISION=2
LABEL org.opencontainers.image.title="web-callback" \
      org.opencontainers.image.version="${APP_VERSION}-r${IMAGE_REVISION}" \
      org.opencontainers.image.description="Ponte OIDC (Web Callback) em Tomcat 10.1 / Java 25"

ENV CATALINA_HOME=/usr/local/tomcat
WORKDIR /usr/local/tomcat

RUN groupadd --system --gid 10001 wcb \
 && useradd  --system --uid 10001 --gid wcb --home-dir /usr/local/tomcat --shell /usr/sbin/nologin wcb \
 # remove apps de exemplo/manager, scripts Windows e usuários do Tomcat
 && rm -rf webapps/* webapps.dist bin/*.bat conf/tomcat-users.* \
 # HostConfig verifica conf/Catalina/localhost no boot
 && mkdir -p conf/Catalina/localhost \
 # somente estes diretórios são graváveis pelo Tomcat (em read_only viram tmpfs)
 && chown -R wcb:wcb work temp logs conf/Catalina

COPY docker/tomcat/server.xml docker/tomcat/logging.properties conf/
# Aplicação: dono root, leitura para todos -> o processo do Tomcat não consegue alterá-la
COPY --from=explode /out/iwlcb webapps/iwlcb

ENV CATALINA_OPTS="-XX:InitialRAMPercentage=50.0 \
 -XX:MaxRAMPercentage=70.0 \
 -XX:MaxMetaspaceSize=192m \
 -XX:+ExitOnOutOfMemoryError \
 -Djava.awt.headless=true \
 -Dfile.encoding=UTF-8 \
 -Duser.timezone=America/Sao_Paulo"

USER 10001:10001
EXPOSE 8080

HEALTHCHECK --interval=15s --timeout=5s --start-period=60s --retries=4 \
  CMD bash -c 'exec 3<>/dev/tcp/127.0.0.1/8080 \
   && printf "GET /iwlcb/health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n" >&3 \
   && head -n1 <&3 | grep -q " 200 "' || exit 1
