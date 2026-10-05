import { Request, Response } from "express";
import { AppDataSource } from "../config/database";
import { redis } from "../config/redis";

const READINESS_TIMEOUT_MS = 2000;

// Sem timeout, o ioredis enfileira comandos quando o Redis cai e o ping nunca responde.
function withTimeout<T>(promise: Promise<T>, name: string): Promise<T> {
  return Promise.race([
    promise,
    new Promise<T>((_, reject) =>
      setTimeout(() => reject(new Error(`${name} timeout`)), READINESS_TIMEOUT_MS).unref()
    ),
  ]);
}

// Liveness: o processo está de pé? Não consulta dependências (evita reinício em cascata).
export function liveness(_req: Request, res: Response) {
  res.status(200).json({ status: "ok" });
}

// Readiness: o pod pode receber tráfego? Verifica Postgres e Redis.
export async function readiness(_req: Request, res: Response) {
  try {
    await Promise.all([
      withTimeout(AppDataSource.query("SELECT 1"), "postgres"),
      withTimeout(redis.ping(), "redis"),
    ]);
    res.status(200).json({ status: "ready" });
  } catch (error: any) {
    res.status(503).json({ status: "not_ready", details: error.message });
  }
}
