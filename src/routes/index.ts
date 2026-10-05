import { Router } from "express";
import { ContractController } from "../controllers/ContractController";
import { metricsController } from "../middlewares/metricsMiddleware";
import { liveness, readiness } from "../controllers/HealthController";

const router = Router();
const contractController = new ContractController();

router.post("/contracts", (req, res, next) => contractController.handle(req, res).catch(next));
router.get("/health", liveness);
router.get("/ready", readiness);
router.get("/metrics", metricsController);

export { router };
