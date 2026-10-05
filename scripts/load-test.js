// Teste de carga com k6 (https://k6.io): criação de contratos.
//   k6 run -e BASE_URL=http://localhost scripts/load-test.js
// Acompanhe no Grafana a latência p95 e, no cluster, o aumento de réplicas (HPA).
import http from "k6/http";
import { check } from "k6";

export const options = {
  stages: [
    { duration: "30s", target: 30 },
    { duration: "1m", target: 100 },
    { duration: "30s", target: 0 },
  ],
  thresholds: { http_req_failed: ["rate<0.01"], http_req_duration: ["p(95)<800"] },
};

const BASE = __ENV.BASE_URL || "http://localhost:3000";

export default function () {
  const res = http.post(
    `${BASE}/contracts`,
    JSON.stringify({ title: `Contrato ${__VU}-${__ITER}`, userId: `user-${__VU}`, description: "carga", value: 100 }),
    { headers: { "Content-Type": "application/json" } }
  );
  check(res, { "201": (r) => r.status === 201 });
}
