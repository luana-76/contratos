.DEFAULT_GOAL := help
KIND_CLUSTER ?= contratos
IMAGE = contratos-api:local

help: ## Lista os comandos
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

init: ## Cria o .env a partir do exemplo (edite as senhas!)
	@test -f .env || (cp .env.example .env && echo ".env criado - ajuste as senhas")

test: ## Testes unitários
	npm ci && npm test

up: init ## Sobe tudo com Docker Compose (API + Postgres + Redis + Prometheus + Grafana)
	docker compose up -d --build

down: ## Derruba o ambiente Compose (mantém volumes)
	docker compose down

clean: ## Derruba o Compose e apaga os volumes
	docker compose down -v

logs: ## Logs da API
	docker compose logs -f api

smoke: ## Teste de fumaça contra o Compose
	./scripts/smoke-test.sh

# ---------- Kubernetes (kind) ----------
k8s-cluster: ## Cria o cluster kind + Ingress NGINX + metrics-server
	kind create cluster --name $(KIND_CLUSTER) --config scripts/kind-cluster.yaml
	kubectl apply -f https://kind.sigs.k8s.io/examples/ingress/deploy-ingress-nginx.yaml
	kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
	kubectl -n kube-system patch deploy metrics-server --type=json \
	  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
	kubectl -n ingress-nginx wait --for=condition=ready pod -l app.kubernetes.io/component=controller --timeout=180s

k8s-build: ## Constrói a imagem e carrega no kind
	docker build -t $(IMAGE) .
	kind load docker-image $(IMAGE) --name $(KIND_CLUSTER)

k8s-deploy: init ## Aplica segredos + manifestos no cluster atual
	./scripts/k8s-deploy.sh

k8s-smoke: ## Teste de fumaça via Ingress (http://localhost)
	BASE_URL=http://localhost SKIP_INTERNAL=1 ./scripts/smoke-test.sh

k8s-destroy: ## Remove o cluster kind
	kind delete cluster --name $(KIND_CLUSTER)
