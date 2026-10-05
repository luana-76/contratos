# Contratos — Infraestrutura DevOps

Repositório de infraestrutura e automação (containers, orquestração, CI/CD e observabilidade) para a API **Contratos**.
Este repositório é independente: contém o código da API, seu Postgres (`contracts_db`), seu Redis e todo o monitoramento.

| Rota | Descrição |
|---|---|
| `POST /contracts` | Cria um contrato (Postgres) e guarda o último no Redis |
| `GET /metrics` | Métricas Prometheus (já existia) |
| `GET /health`, `GET /ready` | Liveness / readiness (adicionados — ver [Alterações](#alterações-no-código-da-api)) |

> A justificativa das decisões (escalabilidade, segurança e confiabilidade) está em **[docs/ARQUITETURA.md](docs/ARQUITETURA.md)**.

## Estrutura

```
src/ tests/ package.json ...   código da API
Dockerfile                     multi-stage, usuário não-root
docker-compose.yml             ambiente local completo (API, Postgres, Redis, Prometheus, Grafana)
k8s/                           manifestos Kubernetes (kustomize): dados, API, HPA, Ingress, NetworkPolicy, monitoramento
monitoring/                    Prometheus (config + alertas) e dashboard do Grafana
.github/workflows/             ci.yml (testes, build, scan) e cd.yml (publica imagem + deploy + rollback)
scripts/                       smoke-test.sh, k8s-deploy.sh, load-test.js (k6), kind-cluster.yaml
Makefile                       atalhos (make help)
```

## Pré-requisitos

- **Caminho A (Docker Compose):** Docker 24+ com Compose v2.
- **Caminho B (Kubernetes local):** Docker, [kind](https://kind.sigs.k8s.io/) e `kubectl` (já inclui kustomize).
- Opcional: Node 22 (testes fora do Docker) e [k6](https://k6.io) (teste de carga).

---

## Caminho A — Docker Compose (mais rápido)

```bash
make init     # cria o .env a partir do .env.example  → EDITE as senhas
make up       # build da imagem + sobe tudo
make smoke    # teste de ponta a ponta
```

Sem `make`: `cp .env.example .env && docker compose up -d --build && ./scripts/smoke-test.sh`.

| Serviço | URL |
|---|---|
| API | http://localhost:3000 |
| Prometheus | http://localhost:9090 |
| Grafana (dashboard "APIs - Visão geral") | http://localhost:3003 (usuário/senha do `.env`) |

Encerrar: `make down` (mantém dados) ou `make clean` (apaga volumes).

### Testar a API manualmente

```bash
# Contrato válido → 201
curl -i -X POST localhost:3000/contracts -H 'Content-Type: application/json' \
  -d '{"title":"Contrato X","userId":"user-1","description":"teste","value":1500.50}'

# Sem campos obrigatórios → 400
curl -i -X POST localhost:3000/contracts -H 'Content-Type: application/json' -d '{}'

curl localhost:3000/metrics | head
```

---

## Caminho B — Kubernetes (kind)

```bash
make init          # e edite as senhas do .env
make k8s-cluster   # kind (1 control-plane + 2 workers) + Ingress NGINX + metrics-server
make k8s-build     # docker build + kind load da imagem
make k8s-deploy    # segredos (do .env) + manifestos + espera os rollouts
make k8s-smoke     # teste de ponta a ponta via Ingress (http://localhost)
```

Tudo roda no namespace `contratos`. Rotas expostas pelo Ingress (somente as de negócio; `/metrics`, `/health` e `/ready` ficam internos):

| Rota | Serviço |
|---|---|
| `POST /contracts` | `contratos` (2–6 pods) |

Observabilidade:

```bash
kubectl -n contratos port-forward svc/grafana 3003:3000      # http://localhost:3003
kubectl -n contratos port-forward svc/prometheus 9090:9090   # http://localhost:9090
```

Ver a escala automática (HPA) durante um teste de carga:

```bash
k6 run -e BASE_URL=http://localhost scripts/load-test.js
kubectl -n contratos get hpa -w
```

Limpar: `make k8s-destroy`.

> **NetworkPolicy:** o CNI padrão do kind (kindnet) não aplica políticas. Os manifestos estão corretos e valem em clusters com Calico/Cilium (a maioria dos gerenciados).

---

## CI/CD (GitHub Actions)

**`ci.yml`** — em todo PR e push na `main`:
1. `typecheck` → testes (Jest) → build → `npm audit` (produção).
2. Valida `docker compose config` e os manifestos (`kustomize` + `kubeconform`).
3. Constrói a imagem e roda **Trivy** (falha com vulnerabilidade HIGH/CRITICAL que tenha correção).

**`cd.yml`** — a cada push na `main`:
1. Publica a imagem no GHCR com a tag do commit (`ghcr.io/<owner>/contratos-api:<sha>`).
2. Aplica os manifestos no cluster com essa tag, espera o `rollout status` e, se falhar, executa **`rollout undo`** automaticamente.

Configuração necessária no GitHub:
- Secret `KUBE_CONFIG_B64`: `base64 -w0 ~/.kube/config` do cluster de destino.
- Environment `production` (opcional: exigir aprovação manual).
- Tornar o pacote do GHCR público, ou criar um `imagePullSecret` no namespace `contratos`.
- Os Secrets do cluster (`db-credentials`, `grafana-admin`) são criados uma vez com `./scripts/k8s-deploy.sh` — nunca vão para o Git.

---

## Alterações no código da API

Mudanças mínimas, necessárias para operar em containers (a lógica de negócio não foi alterada):

| Arquivo | Mudança | Motivo |
|---|---|---|
| `package.json` | scripts `build`, `start`, `test`, `typecheck` | o original não tinha como compilar/iniciar em produção; `test` era um `echo` que falhava |
| `tsconfig.build.json` (novo) | compila `src/` → `dist/` sem os testes | a imagem final só leva JS |
| `src/controllers/HealthController.ts` + rotas | `GET /health` (liveness) e `GET /ready` (Postgres + Redis, timeout de 2 s) | probes do Kubernetes e healthcheck do Docker |
| `src/server.ts` | encerramento gracioso em `SIGTERM`/`SIGINT`; `exit(1)` se o banco não conectar | deploys sem perder requisições; o orquestrador reinicia o container com falha |

## Validação realizada

- Testes unitários: **1/1 passando**; `tsc` e build sem erros.
- Smoke test (`scripts/smoke-test.sh`) com PostgreSQL 16 e Redis reais: **5/5 verificações** OK.
- `/ready` retorna 503 com o Redis fora do ar enquanto `/health` segue 200; `SIGTERM` encerra o processo de forma limpa.
- Manifestos Kubernetes: `kustomize build` + `kubeconform -strict` → **24/24 recursos válidos**.
- **Não executado no ambiente de desenvolvimento** (sem Docker/cluster): `docker build`, `docker compose up`, `kind` e os workflows do GitHub Actions. Rode o Caminho A/B acima para a verificação final.

## Problemas comuns

- `docker compose` reclama de variável obrigatória → rode `make init` e preencha o `.env`.
- HPA mostra `<unknown>` → o metrics-server ainda está subindo (`kubectl -n kube-system get pods`).
- Pod em `ImagePullBackOff` no kind → faltou `make k8s-build` (carrega a imagem local no cluster).
