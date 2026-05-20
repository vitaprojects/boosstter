import { randomUUID } from "node:crypto";

import type { Request, Response } from "express";

import { query } from "../config/db.js";
import { centsFromDecimal } from "../config/pricing.js";

export async function listUsers(req: Request, res: Response) {
  const role = typeof req.query["role"] === "string" ? req.query["role"] : null;
  const result = role
    ? await query("SELECT * FROM app_users WHERE role = $1 ORDER BY created_at DESC", [role])
    : await query("SELECT * FROM app_users ORDER BY created_at DESC");

  res.json({ users: result.rows });
}

export async function createUser(req: Request, res: Response) {
  const body = req.body as Record<string, unknown>;
  const id = typeof body["id"] === "string" ? body["id"] : randomUUID();
  const email = body["email"];

  if (typeof email !== "string" || email.trim().length === 0) {
    res.status(400).json({ error: "email is required" });
    return;
  }

  const result = await query(
    `INSERT INTO app_users (
      id, email, full_name, role, phone_number, country_code, is_available
    ) VALUES ($1, $2, $3, $4, $5, $6, $7)
    RETURNING *`,
    [
      id,
      email.trim().toLowerCase(),
      body["fullName"] ?? null,
      body["role"] ?? "customer",
      body["phoneNumber"] ?? null,
      body["countryCode"] ?? "CA",
      body["isAvailable"] ?? false,
    ],
  );

  res.status(201).json({ user: result.rows[0] });
}

export async function upsertProviderSettings(req: Request, res: Response) {
  const userId = req.params["userId"];
  if (!userId) {
    res.status(400).json({ error: "userId is required" });
    return;
  }

  const body = req.body as Record<string, unknown>;
  const boostPrice = centsFromDecimal(body["boostPrice"], 2500);
  const towPrice = centsFromDecimal(body["towPrice"], 3000);
  const mechanicPrice = centsFromDecimal(body["mechanicPrice"], 3500);

  const result = await query(
    `INSERT INTO service_providers (
      user_id, provides_boost, provides_tow, provides_mechanic,
      boost_price_cents, tow_price_cents, mechanic_price_cents,
      currency, request_notifications, preferred_payment_provider
    ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
    ON CONFLICT (user_id) DO UPDATE SET
      provides_boost = EXCLUDED.provides_boost,
      provides_tow = EXCLUDED.provides_tow,
      provides_mechanic = EXCLUDED.provides_mechanic,
      boost_price_cents = EXCLUDED.boost_price_cents,
      tow_price_cents = EXCLUDED.tow_price_cents,
      mechanic_price_cents = EXCLUDED.mechanic_price_cents,
      currency = EXCLUDED.currency,
      request_notifications = EXCLUDED.request_notifications,
      preferred_payment_provider = EXCLUDED.preferred_payment_provider,
      updated_at = NOW()
    RETURNING *`,
    [
      userId,
      body["providesBoost"] ?? true,
      body["providesTow"] ?? false,
      body["providesMechanic"] ?? false,
      boostPrice,
      towPrice,
      mechanicPrice,
      body["currency"] ?? "CAD",
      body["requestNotifications"] ?? true,
      body["preferredPaymentProvider"] ?? "stripe",
    ],
  );

  await query("UPDATE app_users SET role = 'driver', updated_at = NOW() WHERE id = $1", [
    userId,
  ]);

  res.json({ provider: result.rows[0] });
}
