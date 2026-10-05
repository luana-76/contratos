# Justificativa de Arquitetura — Contratos

## 1. O que a API exige

Ler o código antes de desenhar a infraestrutura mostrou requisitos que moldaram as decisões:

| Observação no código | Consequência na infraestrutura |
|---|---|
| API **stateless** (estado em Postgres/Redis) | Escala horizontalmente com réplicas atrás de um balanceador |
| Cada criação grava no Postgres **e** no Redis (cache do último contrato, TTL 1 h) | Readiness verifica as duas dependências; Redis com persistência (AOF) |
| Escrita transacional de contratos | Postgres em StatefulSet com volume persistente |
| `/metrics` (prom-client) já existe | Prometheus + Grafana + alertas, sem alterar a aplicação |
| `synchronize: true` no TypeORM | Aceitável para a atividade; em produção exigiria *migrations* (ver §7) |

## 2. Visão geral

```
                      ┌──────────────── GitHub Actions ────────────────┐
  git push ─────────▶ │ CI: typecheck · testes · build · audit · Trivy │
                      │ CD: build → GHCR (tag = SHA) → kubectl apply   │
                      │     rollout status → rollback automático       │
                      └───────────────────────┬────────────────────────┘
                                              ▼   namespace "contratos"
  Cliente ──▶ Ingress NGINX ── /contracts ──▶ contratos (2–6 pods, HPA)
                                                      │                 │
                                            PostgreSQL (StatefulSet+PVC)  Redis (AOF+PVC)
  Prometheus ◀── scrape /metrics (pods anotados) ── Grafana (dashboard + alertas)
```

O mesmo conjunto roda localmente com `docker compose` (sem Kubernetes) para desenvolvimento e testes rápidos.

## 3. Escalabilidade

- **Escala horizontal automática:** `HorizontalPodAutoscaler` por CPU (70 %), de 2 a 6 réplicas.
- **Requests/limits em todos os containers:** o scheduler distribui corretamente e o HPA calcula utilização sobre o `request`.
- **API sem estado:** qualquer réplica atende qualquer requisição; o estado vive em Postgres/Redis.
- **Distribuição entre nós:** `topologySpreadConstraints`; `scripts/load-test.js` (k6) valida o comportamento sob carga.

## 4. Confiabilidade

- **Deploy sem downtime:** `RollingUpdate` com `maxUnavailable: 0` + `readinessProbe`; o tráfego só chega em pods que passaram em `/ready`.
- **Probes com papéis distintos:** `startupProbe` (boot), `readinessProbe` em `/ready` (verifica Postgres **e** Redis com timeout de 2 s — se uma dependência cai, o pod sai do balanceamento sem ser reiniciado) e `livenessProbe` em `/health` (não consulta dependências, evitando reinícios em cascata).
- **Encerramento gracioso:** `SIGTERM` fecha o servidor HTTP e as conexões antes de sair; `terminationGracePeriodSeconds: 30`.
- **PodDisruptionBudget:** manutenção de nós nunca remove todas as réplicas.
- **Rollback automático:** o CD falha e executa `rollout undo` se o novo release não ficar saudável em 180 s. Cada imagem é imutável e rastreável pelo SHA do commit.
- **Persistência:** Postgres e Redis (AOF) em `StatefulSet` com volumes persistentes.
- **Observabilidade e alertas:** Prometheus coleta `/metrics`; alertas para API fora do ar, taxa de 5xx > 5 %, p95 > 1 s e lag do event loop > 500 ms. Dashboard Grafana provisionado como código.

## 5. Segurança

- **Imagem enxuta e não-root:** build multi-stage, `node:22-alpine`, apenas dependências de produção, usuário `node`.
- **Hardening dos pods:** `runAsNonRoot`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`, `capabilities: drop ALL`, `seccompProfile: RuntimeDefault`; o namespace aplica o Pod Security Standard *restricted*.
- **Segredos fora do Git:** senhas vêm de `.env` (ignorado pelo Git) e viram `Secret` do Kubernetes via `scripts/k8s-deploy.sh`; o `docker-compose.yml` exige as variáveis (`:?`) em vez de ter padrões inseguros.
- **Menor superfície de ataque:** o Ingress expõe só as rotas de negócio; `/metrics`, `/health` e `/ready` ficam internos.
- **Rede zero-trust:** `NetworkPolicy` nega todo ingress por padrão; Postgres e Redis só aceitam conexões dos pods da API; a API só aceita o Ingress e o Prometheus; o Prometheus só aceita o Grafana.
- **Supply chain no CI:** `npm audit`, **Trivy** na imagem (bloqueia HIGH/CRITICAL corrigíveis), versões de imagens fixadas, `permissions` mínimas nos workflows e RBAC do Prometheus restrito a leitura de pods.

## 6. Mapeamento com as práticas DevOps

| Prática | Onde está |
|---|---|
| Infraestrutura como código | `docker-compose.yml`, `k8s/`, `monitoring/` — tudo versionado e reproduzível |
| Integração contínua | `.github/workflows/ci.yml` |
| Entrega contínua + rollback | `.github/workflows/cd.yml` |
| Containers e imutabilidade | `Dockerfile` multi-stage, imagens por SHA |
| Automação / reprodutibilidade | `Makefile`, `scripts/`, README passo a passo |
| Monitoramento e feedback | Prometheus, Grafana, alertas, `scripts/load-test.js` |
| Segurança integrada ao pipeline (DevSecOps) | Trivy, `npm audit`, hardening, NetworkPolicy |

## 7. Limitações conscientes e próximos passos

Escolhas feitas para manter a atividade reproduzível em uma máquina local; em produção real eu evoluiria:

- **Postgres e Redis gerenciados** (RDS/Cloud SQL, ElastiCache) ou com operador/HA e backups — hoje são instância única.
- **Migrations** (TypeORM) no lugar de `synchronize: true`, executadas como Job no pipeline.
- **TLS** (cert-manager) e um gerenciador de segredos (External Secrets / Vault) no lugar de `Secret` criado por script.
- **Provisionamento do cluster com Terraform** e ambientes separados (staging/produção) com *overlays* do kustomize.
- **Logs centralizados** (Loki/ELK) e tracing (OpenTelemetry).
- **Autenticação/autorização** nas rotas — a API original não tem, e isso é responsabilidade da aplicação.
