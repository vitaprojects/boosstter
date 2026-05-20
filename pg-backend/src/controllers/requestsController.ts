import { randomUUID } from "node:crypto";

import type { Request, Response } from "express";

import { query } from "../config/db.js";
import { buildChargeBreakdown } from "../config/pricing.js";

const priceFieldByService: Record<string, string> = {
  boost: "boost_price_cents",
  tow: "tow_price_cents",
  mobile_mechanic: "mechanic_price_cents",
};

export async function listRequests(req: Request, res: Response) {
  const status = typeof req.query["status"] === "string" ? req.query["status"] : null;
  const result = status
    ? await query("SELECT * FROM service_requests WHERE status = $1 ORDER BY created_at DESC", [
        status,
      ])
    : await query("SELECT * FROM service_requests ORDER BY created_at DESC");

  res.json({ requests: result.rows });
}

export async function createRequest(req: Request, res: Response) {
  const body = req.body as Record<string, unknown>;
  const serviceType =
    typeof body["serviceType"] === "string" ? body["serviceType"] : "boost";
  const providerId = body["providerId"];
  const customerId = body["customerId"];

  if (typeof customerId !== "string" || typeof providerId !== "string") {
    res.status(400).json({ error: "customerId and providerId are required" });
    return;
  }

  const provider = await query<Record<string, unknown>>(
    `SELECT app_users.country_code, service_providers.*
     FROM service_providers
     JOIN app_users ON app_users.id = service_providers.user_id
     WHERE user_id = $1`,
    [providerId],
  );

  const providerRow = provider.rows[0];
  const priceField = priceFieldByService[serviceType] ?? "boost_price_cents";
  const serviceCents = Number(providerRow?.[priceField] ?? 2500);
  const currency = String(providerRow?.["currency"] ?? "CAD");
  const countryCode = String(body["countryCode"] ?? providerRow?.["country_code"] ?? "CA");
  const paymentProvider = String(providerRow?.["preferred_payment_provider"] ?? "stripe");
  const breakdown = buildChargeBreakdown(serviceCents, countryCode);

  const id = randomUUID();
  const result = await query(
    `INSERT INTO service_requests (
      id, customer_id, provider_id, service_type, status, payment_status,
      vehicle_make, vehicle_model, vehicle_label, vehicle_type,
      vehicle_location_address, vehicle_location_latitude, vehicle_location_longitude,
      service_charge_cents, tax_cents, total_charge_cents, admin_fee_cents,
      provider_payout_cents, currency, payment_provider, stage
    ) VALUES (
      $1, $2, $3, $4, 'pending', 'awaiting_provider_acceptance',
      $5, $6, $7, $8, $9, $10, $11,
      $12, $13, $14, $15, $16, $17, $18, 'provider_requested'
    )
    RETURNING *`,
    [
      id,
      customerId,
      providerId,
      serviceType,
      body["vehicleMake"] ?? null,
      body["vehicleModel"] ?? null,
      body["vehicleLabel"] ?? null,
      body["vehicleType"] ?? null,
      body["vehicleLocationAddress"] ?? null,
      body["vehicleLocationLatitude"] ?? null,
      body["vehicleLocationLongitude"] ?? null,
      breakdown.serviceChargeCents,
      breakdown.taxCents,
      breakdown.totalChargeCents,
      breakdown.adminFeeCents,
      breakdown.providerPayoutCents,
      currency,
      paymentProvider,
    ],
  );

  await query(
    `INSERT INTO app_notifications (
      id, request_id, recipient_id, audience, stage, title, body
    ) VALUES ($1, $2, $3, 'provider', 'provider_requested', 'New service request', $4)`,
    [
      randomUUID(),
      id,
      providerId,
      `New ${serviceType} request at ${String(body["vehicleLocationAddress"] ?? "vehicle location")}`,
    ],
  );

  res.status(201).json({ request: result.rows[0] });
}

export async function updateRequestStage(req: Request, res: Response) {
  const requestId = req.params["id"];
  const body = req.body as Record<string, unknown>;
  const status = typeof body["status"] === "string" ? body["status"] : null;
  const paymentStatus =
    typeof body["paymentStatus"] === "string" ? body["paymentStatus"] : undefined;

  if (!requestId || !status) {
    res.status(400).json({ error: "request id and status are required" });
    return;
  }

  const result = await query(
    `UPDATE service_requests SET
      status = $2,
      payment_status = COALESCE($3, payment_status),
      stage = $2,
      updated_at = NOW(),
      paid_at = CASE WHEN $2 = 'paid' OR $3 = 'paid' THEN COALESCE(paid_at, NOW()) ELSE paid_at END,
      accepted_at = CASE WHEN $2 = 'accepted' THEN COALESCE(accepted_at, NOW()) ELSE accepted_at END,
      completed_at = CASE WHEN $2 = 'completed' THEN COALESCE(completed_at, NOW()) ELSE completed_at END,
      cancelled_at = CASE WHEN $2 = 'cancelled' THEN COALESCE(cancelled_at, NOW()) ELSE cancelled_at END
    WHERE id = $1
    RETURNING *`,
    [requestId, status, paymentStatus ?? null],
  );

  if (!result.rows[0]) {
    res.status(404).json({ error: "request not found" });
    return;
  }

  res.json({ request: result.rows[0] });
}
