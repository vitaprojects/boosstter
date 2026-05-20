import cors from "cors";
import express from "express";

import { config } from "./config/env.js";
import { initializeDatabase, pool } from "./config/db.js";
import { requireAdmin } from "./middleware/auth.js";
import { adminRoutes } from "./routes/adminRoutes.js";

const app = express();

app.use(cors({ origin: config.corsOrigin }));
app.use(express.json({ limit: "1mb" }));

app.get("/health", (_req, res) => {
  res.json({ ok: true, service: "boosstter-pg-backend" });
});

app.use("/admin", requireAdmin, adminRoutes);

app.use((err: unknown, _req: express.Request, res: express.Response, _next: express.NextFunction) => {
  console.error(err);
  res.status(500).json({
    error: "Internal Server Error",
    message: err instanceof Error ? err.message : "Unexpected backend error",
  });
});

async function main() {
  await initializeDatabase();
  app.listen(config.port, () => {
    console.log(`Boosstter demo PostgreSQL backend running on port ${config.port}`);
    console.log(`Temporary admin username: ${config.tempAdminUsername}`);
  });
}

main().catch(async (error: unknown) => {
  console.error("Failed to start backend", error);
  await pool.end();
  process.exit(1);
});
