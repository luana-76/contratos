import { app } from "./app";
import { AppDataSource } from "./config/database";
import { redis } from "./config/redis";

const PORT = process.env.PORT || 3000;

AppDataSource.initialize()
  .then(() => {
    console.log("Data Source has been initialized!");
    const server = app.listen(PORT, () => {
      console.log(`Server is running on port ${PORT}`);
    });

    // Encerramento gracioso: o Kubernetes/Docker envia SIGTERM em deploys e scale-down.
    const shutdown = (signal: string) => {
      console.log(`${signal} received, shutting down gracefully...`);
      server.close(async () => {
        await AppDataSource.destroy().catch(() => undefined);
        redis.disconnect();
        process.exit(0);
      });
      setTimeout(() => process.exit(1), 25_000).unref();
    };
    process.on("SIGTERM", () => shutdown("SIGTERM"));
    process.on("SIGINT", () => shutdown("SIGINT"));
  })
  .catch((err) => {
    console.error("Error during Data Source initialization:", err);
    process.exit(1);
  });
