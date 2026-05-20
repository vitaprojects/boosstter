import dotenv from "dotenv";
import dotenvExpand from "dotenv-expand";

dotenvExpand.expand(dotenv.config());

export const config = {
  nodeEnv: process.env["NODE_ENV"] ?? "development",
  port: Number(process.env["PORT"] ?? 4000),
  databaseUrl:
    process.env["DATABASE_URL"] ??
    "postgres://postgres:postgres@localhost:5432/booster_demo",
  corsOrigin: process.env["CORS_ORIGIN"] ?? "*",
  tempAdminUsername: process.env["TEMP_ADMIN_USERNAME"] ?? "demo_admin",
  tempAdminPassword: process.env["TEMP_ADMIN_PASSWORD"] ?? "BoosterDemo2026!",
};
