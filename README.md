# Web Callback (Ponte OIDC) — Tomcat + Redis em containers (validação)

`br.com.senior.xt.idp:web-callback:1.0.0` · contexto `/iwlcb`

```text
Cliente ─HTTPS :443─► [wcb-proxy] nginx (TLS: certs/tls.crt + tls.key)   ≙ Ingress no K8s
        ─HTTP  :80 ─► 301 → https            │ HTTP interno, X-Forwarded-*
                                              ▼
                       [wcb-app]  Tomcat 10.1 + Java 25 + /iwlcb   (8080 só em 127.0.0.1)
                                              │ REDIS_HOST=redis
                                              ▼
                       [wcb-redis] Redis 7.4  (só rede interna)

wcb-app ──HTTPS──► Plataforma Senior (user-info)  ← validação da credencial na "ida"
```

## Por que esta composição

| Requisito do guia | Como foi atendido |
|---|---|
| Tomcat 10.1 / Servlet 6 / `jakarta.*` / Java 25 | Base `tomcat:10.1-jdk25-temurin` (a mesma do guia) |
| WAR em `/usr/local/tomcat/webapps/`, contexto `/iwlcb` | WAR copiado como `iwlcb.war` |
| Config 100% por env (12-factor) | `.env` → `environment` no compose; nada na imagem |
| Fail-fast se Redis inacessível no boot | `depends_on: condition: service_healthy` |
| Sem fallback para memória | `BRIDGE_TRANSACTION_STORE=redis` |
| `/iwlcb/health` | `HEALTHCHECK` do Docker usa esse endpoint |

O guia define que **host, porta e TLS são do ingress/proxy** (a app não lê host). Por isso o
TLS termina no `wcb-proxy` e o Tomcat continua só em HTTP interno — a **mesma imagem** vai
para o Kubernetes, onde o proxy é substituído pelo Ingress.

## Estrutura

```text
docker/Dockerfile           imagem da aplicação (multi-stage, JRE, WAR expandido)
docker/tomcat/server.xml    Tomcat enxuto (sem shutdown port, erros sem versão, RemoteIpValve)
docker/tomcat/logging.properties  logs do Tomcat só em stdout
docker/nginx/web-callback.conf    proxy TLS (papel do Ingress)
certs/                      tls.crt + tls.key (não versionar)
docker-compose.yml          proxy + app + redis
docker-compose.tls.yml      overlay opcional: Redis com TLS (REDIS_SSL=true)
.env.example                todas as variáveis da §4 do guia
scripts/download-war.sh     baixa o WAR do Nexus e confere o SHA-1
scripts/smoke-test.sh       valida containers, rede, deploy e health
scripts/test-flow.sh        cenários negativos + ida + volta + anti-replay
scripts/check-https.sh      valida certificado, TLS e hardening (sem versão exposta)
tls/gen-redis-tls.sh        gera CA/cert do Redis + truststore Java
artifacts/                  onde o WAR é colocado
```

## Pré-requisitos no servidor Linux

- Docker Engine 24+ com plugin `docker compose`
- Acesso de saída a `nexus.senior.com.br` (ou copiar o WAR manualmente para `artifacts/`)
- Acesso ao Docker Hub (ou registry espelho) para `tomcat:10.1-jdk25-temurin` e `redis:7.4-alpine`
- **Saída HTTPS do container para a plataforma Senior** — sem isso a ida retorna `503`
- `curl`, `unzip`, `openssl` (para os scripts)

## Passo a passo

```bash
# 1. Copiar a pasta para o servidor e entrar nela
cd web-callback-docker

# 2. Baixar o WAR (se o Nexus pedir login: NEXUS_USER=seu.usuario ./scripts/download-war.sh)
./scripts/download-war.sh

# 3. Configurar
cp .env.example .env && chmod 600 .env
sed -i "s|TROQUE_POR_UMA_SENHA_FORTE|$(openssl rand -base64 32 | tr -d '=+/')|" .env
vi .env     # ajuste BRIDGE_PLATFORM_ENV ao ambiente da credencial que você vai usar

# 4. Subir
docker compose up -d --build
docker compose logs -f web-callback      # aguarde "Deployment of web application directory [.../iwlcb] has finished"

# 5. Validar
curl -i http://localhost:8080/iwlcb/health      # 200 {"status":"UP"}
./scripts/smoke-test.sh
SERVICE_TOKEN='<bearer da credencial de serviço>' TENANT='<tenant>' ./scripts/smoke-test.sh
```

## HTTPS com seu certificado

```bash
cp /caminho/seu.crt certs/tls.crt      # certificado do servidor + intermediárias (PEM, nessa ordem)
cp /caminho/seu.key certs/tls.key      # chave privada PEM SEM senha
# se tiver a cadeia separada:  cat seu.crt intermediaria.crt > certs/tls.crt
# se a chave tiver senha:      openssl pkey -in seu.key -out certs/tls.key
chown 101:101 certs/tls.key && chmod 400 certs/tls.key   # 101 = usuário do nginx no container

# conferir: a 1ª linha da chave deve ser "-----BEGIN PRIVATE KEY-----" (ou RSA/EC PRIVATE KEY)
head -1 certs/tls.key
# chave e certificado do mesmo par (os dois hashes devem ser iguais)
openssl x509 -in certs/tls.crt -noout -pubkey | openssl sha256
openssl pkey -in certs/tls.key -pubout      | openssl sha256

# se recebeu .pfx/.p12:
#   openssl pkcs12 -in cert.pfx -nokeys  -clcerts -out certs/tls.crt
#   openssl pkcs12 -in cert.pfx -nocerts -nodes   -out certs/tls.key
chmod 644 certs/tls.crt

docker compose up -d --build
DOMAIN=<nome do certificado> ./scripts/check-https.sh
BASE_URL=https://<nome>/iwlcb ./scripts/test-flow.sh
```

No NSG/firewall: liberar **443** (e 80 para o redirect) e **remover a regra da 8080**.

### Trocar o certificado (renovação)

```bash
cp novo.crt certs/tls.crt && cp novo.key certs/tls.key
docker exec wcb-proxy nginx -s reload        # sem derrubar conexões nem o Tomcat
```

### Equivalência com Kubernetes (Fase 3)

| Aqui (Docker) | Kubernetes |
|---|---|
| `certs/tls.crt` + `certs/tls.key` | `kubectl create secret tls wcb-tls --cert=certs/tls.crt --key=certs/tls.key` |
| `wcb-proxy` (nginx, 443→8080) | `Ingress` com `tls: [{hosts: [...], secretName: wcb-tls}]` |
| `upstream web-callback:8080` | `Service` ClusterIP porta 8080 |
| `X-Forwarded-*` + `RemoteIpValve` | mesmo comportamento com o ingress-nginx |
| `read_only` + `tmpfs` | `readOnlyRootFilesystem: true` + `emptyDir` em work/temp/logs |
| `user 10001`, `cap_drop ALL` | `runAsNonRoot`, `runAsUser: 10001`, `capabilities.drop: [ALL]` |

Nenhum certificado entra na imagem: o mesmo artefato roda em qualquer ambiente.

## Hardening aplicado (Fase 2)

| Item | Antes | Agora |
|---|---|---|
| Página de erro (404/500) | mostrava `Apache Tomcat/10.1.60` | `ErrorReportValve showServerInfo=false showReport=false` + proxy responde 404 JSON fora de `/iwlcb/` |
| Header `Server` | — | nginx com `server_tokens off` (sem versão) |
| `/health` e `X-App-Version` | build-info exposto | `BRIDGE_HEALTH_VERBOSE=false` |
| Porta de shutdown 8005 | aberta no container | `Server port="-1"` (para via SIGTERM) |
| Runtime | JDK completo | JRE (`RUNTIME_IMAGE`) |
| WAR | expandido em runtime em `webapps/` | expandido no build, dono root, somente-leitura |
| Filesystem | gravável | `read_only` + `tmpfs` em `work/`, `temp/`, `logs/` |
| Logs do Tomcat | stdout + arquivos em `logs/` | só stdout |
| Listeners/realms | APR, UserDatabase, LockOutRealm | removidos (sem manager, sem tomcat-users) |
| Args da JVM no log | impressos no boot | `logArgs=false` (evita vazar senha de truststore) |
| Métodos HTTP | todos | proxy só aceita GET/POST em `/iwlcb/`; TRACE bloqueado |
| Tomcat exposto | 0.0.0.0:8080 | só `127.0.0.1:8080` (externo apenas via 443) |

**O que pode quebrar** (e como reverter):
- `RUNTIME_IMAGE` JRE inexistente no seu registry → use `tomcat:10.1-jdk25-temurin` no `.env`.
- Escrita em disco não prevista → `Read-only file system` no log; comente `read_only` e
  me envie o caminho para criarmos o `tmpfs`/volume certo.
- Se o WAR tiver `META-INF/context.xml` que dependa de `conf/` padrão, o log do deploy mostra.

### Validando a volta (redirect)

A volta depende do Keycloak redirecionar para `/iwlcb/redirect/v1`. O `redirect_uri` só está
liberado para o client `senior-xt` e para a URL pública `https://xt.seniorcloud.com.br/iwlcb/*`.
Para testar a volta **ponta a ponta** a partir deste servidor é preciso pedir ao SRE o cadastro
do host do servidor no client. Sem isso, valide a volta manualmente:

```bash
curl -i "http://localhost:8080/iwlcb/redirect/v1?state=<transaction_id>&code=teste"
# esperado: 302 com Location = return_uri contendo o code cifrado (até o TTL de 60 s expirar)
# reutilizar o mesmo state deve dar 400 (anti-replay)
```

### Validando com Redis em TLS (recomendado antes de produção)

O guia exige `REDIS_SSL=true` em produção. Para simular:

```bash
./tls/gen-redis-tls.sh
docker compose -f docker-compose.yml -f docker-compose.tls.yml up -d
./scripts/smoke-test.sh
```

O truststore gerado é **cópia do `cacerts` do JDK + a CA local**. Se a JVM apontasse só para a
CA local, deixaria de confiar nas CAs públicas e a chamada HTTPS à plataforma Senior falharia.

## Operação e diagnóstico

```bash
docker compose ps                                   # estado + health
docker logs -f wcb-app                              # Tomcat + logback (stdout)
docker stats wcb-app wcb-redis                      # memória/CPU reais
docker exec wcb-redis sh -c 'redis-cli --no-auth-warning -a "$REDIS_PASSWORD" --scan --pattern "iwlcb:txn:*"'
docker exec wcb-app bash -c 'exec 3<>/dev/tcp/redis/6379 && echo conectou'
docker compose down                                 # para tudo (Redis não persiste nada: dados são TTL)
```

| Sintoma | Camada provável | O que olhar |
|---|---|---|
| HTTPS falha / `ERR_CERT` | Proxy / certificado | `./scripts/check-https.sh`; nome do cert ≠ host; falta intermediária; `docker logs wcb-proxy` |
| 502 Bad Gateway no 443 | Proxy → Tomcat | `wcb-app` saudável? `docker logs wcb-app` |
| `/iwlcb/health` = 404, Tomcat no ar | Deploy do WAR falhou (fail-fast) | `docker logs wcb-app` → `SEVERE`; env faltando, Redis, `BRIDGE_PLATFORM_ENV` inválido |
| `NoAuth`/`WRONGPASS` no log | Senha | `REDIS_PASSWORD` igual nos dois serviços (vem do mesmo `.env`) |
| Timeout em `redis:6379` | Rede Docker | ambos na rede `wcb-backend`? `REDIS_HOST=redis`? |
| Ida → `401` | Credencial | token expirado ou de outro ambiente que `BRIDGE_PLATFORM_ENV` |
| Ida → `503` | Saída de rede | firewall/proxy do servidor bloqueando HTTPS à plataforma |
| Container reinicia com exit 3/137 | Memória | `ExitOnOutOfMemoryError` / OOM do cgroup → ajustar `mem_limit` |

> Atenção: se o WAR falhar ao iniciar, **o Tomcat continua de pé** (o container não morre). Quem
> sinaliza o problema é o healthcheck (`unhealthy`) — não confie só em "container Up".

## Decisões de dimensionamento

- **App:** `mem_limit: 1g`, heap máx. 70 % (~716 MB), metaspace ≤ 192 MB; restante para threads
  do Tomcat, buffers nativos e TLS. Ajuste olhando `docker stats` sob carga.
- **Redis:** 256 MB, `noeviction` (com memória cheia o Redis recusa escrita em vez de apagar
  transações em voo), sem RDB/AOF (dados efêmeros com TTL de 60 s).
- **Pool Jedis:** `BRIDGE_REDIS_MAX_TOTAL=10` por instância; com N réplicas → 10×N conexões no Redis.

## O que fica para as próximas fases

- **Fase 2 – pendente:** fixar tags por patch + digest; scan das imagens (Trivy/Grype);
  `REDIS_SSL=true` (overlay TLS) como padrão.
- **Fase 3 – Kubernetes:** Deployment (2+ réplicas, app é stateless), Service, Ingress,
  startup/readiness/liveness em `/iwlcb/health`, Secret para `REDIS_*`, Redis HA da infra.
- **Fase 4 – CI/CD:** pipeline que puxa o WAR do Nexus, gera a imagem uma vez e promove
  DEV → HML → PROD por tag/digest.
