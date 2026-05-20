import type { Request, Response } from "express";

import { query } from "../config/db.js";

export async function getDashboard(_req: Request, res: Response) {
  const [users, requests, revenue] = await Promise.all([
    query<{ total_users: string; providers: string; available_providers: string }>(`
      SELECT
        COUNT(*)::TEXT AS total_users,
        COUNT(*) FILTER (WHERE role = 'driver')::TEXT AS providers,
        COUNT(*) FILTER (WHERE role = 'driver' AND is_available = TRUE)::TEXT AS available_providers
      FROM app_users
    `),
    query<{ status: string; count: string }>(`
      SELECT status, COUNT(*)::TEXT AS count
      FROM service_requests
      GROUP BY status
      ORDER BY status
    `),
    query<{
      total_charge_cents: string;
      admin_fee_cents: string;
      provider_payout_cents: string;
    }>(`
      SELECT
        COALESCE(SUM(total_charge_cents), 0)::TEXT AS total_charge_cents,
        COALESCE(SUM(admin_fee_cents), 0)::TEXT AS admin_fee_cents,
        COALESCE(SUM(provider_payout_cents), 0)::TEXT AS provider_payout_cents
      FROM service_requests
      WHERE payment_status = 'paid'
    `),
  ]);

  res.json({
    users: {
      total: Number(users.rows[0]?.total_users ?? 0),
      providers: Number(users.rows[0]?.providers ?? 0),
      availableProviders: Number(users.rows[0]?.available_providers ?? 0),
    },
    requestsByStatus: Object.fromEntries(
      requests.rows.map((row) => [row.status, Number(row.count)]),
    ),
    money: {
      totalChargeCents: Number(revenue.rows[0]?.total_charge_cents ?? 0),
      adminFeeCents: Number(revenue.rows[0]?.admin_fee_cents ?? 0),
      providerPayoutCents: Number(revenue.rows[0]?.provider_payout_cents ?? 0),
    },
  });
}
