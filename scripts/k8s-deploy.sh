#!/usr/bin/env bash
# Deploy completo no cluster atual (kind/minikube/nuvem).
# Segredos são criados a partir do .env (nunca versionados); o dashboard do Grafana
# vem da mesma fonte usada no docker compose (monitoring/grafana/dashboards).
set -euo pipefail
cd "$(dirname "$0")/.."
NS=contratos

[ -f .env ] || { echo "Arquivo .env não encontrado. Rode: make init"; exit 1; }
set -a; . ./.env; set +a

echo ">> Namespace"
kubectl apply -f k8s/00-namespace.yaml

echo ">> Segredos"
kubectl -n $NS create secret generic db-credentials \
  --from-literal=DB_USER="${POSTGRES_USER:-postgres}" \
  --from-literal=DB_PASSWORD="${POSTGRES_PASSWORD:?defina POSTGRES_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n $NS create secret generic grafana-admin \
  --from-literal=GRAFANA_ADMIN_USER="${GRAFANA_ADMIN_USER:-admin}" \
  --from-literal=GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:?defina GRAFANA_ADMIN_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ">> Dashboard do Grafana"
kubectl -n $NS create configmap grafana-dashboards \
  --from-file=monitoring/grafana/dashboards/apis-overview.json \
  --dry-run=client -o yaml | kubectl apply -f -

echo ">> Manifestos (kustomize)"
kubectl apply -k k8s

echo ">> Aguardando os componentes ficarem prontos"
kubectl -n $NS rollout status statefulset/postgres --timeout=180s
kubectl -n $NS rollout status statefulset/redis --timeout=120s
for d in contratos; do
  kubectl -n $NS rollout status deploy/$d --timeout=180s
done
kubectl -n $NS rollout status deploy/prometheus --timeout=120s
kubectl -n $NS rollout status deploy/grafana --timeout=120s

echo
echo "Pronto. Teste com:  make k8s-smoke"
echo "Grafana:    kubectl -n $NS port-forward svc/grafana 3003:3000"
echo "Prometheus: kubectl -n $NS port-forward svc/prometheus 9090:9090"
