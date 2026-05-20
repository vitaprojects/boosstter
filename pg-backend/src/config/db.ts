import pg from "pg";

import { config } from "./env.js";

const { Pool } = pg;

export const pool = new Pool({
  connectionString: config.databaseUrl,
});

export async function query<T extends pg.QueryResultRow>(
  text: string,
  params: unknown[] = [],
) {
  return pool.query<T>(text, params);
}

export async function initializeDatabase() {
  await query(`
    CREATE TABLE IF NOT EXISTS app_users (
      id TEXT PRIMARY KEY,
      email TEXT UNIQUE NOT NULL,
      full_name TEXT,
      role TEXT NOT NULL DEFAULT 'customer',
      phone_number TEXT,
      country_code TEXT DEFAULT 'CA',
      is_available BOOLEAN NOT NULL DEFAULT FALSE,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );

    CREATE TABLE IF NOT EXISTS service_providers (
      user_id TEXT PRIMARY KEY REFERENCES app_users(id) ON DELETE CASCADE,
      provides_boost BOOLEAN NOT NULL DEFAULT TRUE,
      provides_tow BOOLEAN NOT NULL DEFAULT FALSE,
      provides_mechanic BOOLEAN NOT NULL DEFAULT FALSE,
      boost_price_cents INTEGER NOT NULL DEFAULT 2500,
      tow_price_cents INTEGER NOT NULL DEFAULT 3000,
      mechanic_price_cents INTEGER NOT NULL DEFAULT 3500,
      currency TEXT NOT NULL DEFAULT 'CAD',
      request_notifications BOOLEAN NOT NULL DEFAULT TRUE,
      preferred_payment_provider TEXT NOT NULL DEFAULT 'stripe',
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );

    CREATE TABLE IF NOT EXISTS service_requests (
      id TEXT PRIMARY KEY,
      customer_id TEXT REFERENCES app_users(id) ON DELETE SET NULL,
      provider_id TEXT REFERENCES app_users(id) ON DELETE SET NULL,
      service_type TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'pending',
      payment_status TEXT NOT NULL DEFAULT 'awaiting_provider_acceptance',
      vehicle_make TEXT,
      vehicle_model TEXT,
      vehicle_label TEXT,
      vehicle_type TEXT,
      vehicle_location_address TEXT,
      vehicle_location_latitude DOUBLE PRECISION,
      vehicle_location_longitude DOUBLE PRECISION,
      service_charge_cents INTEGER NOT NULL DEFAULT 0,
      tax_cents INTEGER NOT NULL DEFAULT 0,
      total_charge_cents INTEGER NOT NULL DEFAULT 0,
      admin_fee_cents INTEGER NOT NULL DEFAULT 0,
      provider_payout_cents INTEGER NOT NULL DEFAULT 0,
      currency TEXT NOT NULL DEFAULT 'CAD',
      payment_provider TEXT NOT NULL DEFAULT 'stripe',
      stage TEXT NOT NULL DEFAULT 'provider_requested',
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      paid_at TIMESTAMPTZ,
      accepted_at TIMESTAMPTZ,
      completed_at TIMESTAMPTZ,
      cancelled_at TIMESTAMPTZ
    );

    CREATE TABLE IF NOT EXISTS service_messages (
      id TEXT PRIMARY KEY,
      request_id TEXT NOT NULL REFERENCES service_requests(id) ON DELETE CASCADE,
      sender_id TEXT REFERENCES app_users(id) ON DELETE SET NULL,
      recipient_id TEXT REFERENCES app_users(id) ON DELETE SET NULL,
      body TEXT NOT NULL,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );

    CREATE TABLE IF NOT EXISTS service_reviews (
      id TEXT PRIMARY KEY,
      request_id TEXT NOT NULL REFERENCES service_requests(id) ON DELETE CASCADE,
      reviewer_id TEXT REFERENCES app_users(id) ON DELETE SET NULL,
      reviewee_id TEXT REFERENCES app_users(id) ON DELETE SET NULL,
      rating INTEGER NOT NULL CHECK (rating BETWEEN 1 AND 5),
      comment TEXT,
      is_customer_review BOOLEAN NOT NULL,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );

    CREATE TABLE IF NOT EXISTS app_notifications (
      id TEXT PRIMARY KEY,
      request_id TEXT REFERENCES service_requests(id) ON DELETE CASCADE,
      recipient_id TEXT REFERENCES app_users(id) ON DELETE CASCADE,
      audience TEXT NOT NULL,
      stage TEXT NOT NULL,
      title TEXT NOT NULL,
      body TEXT NOT NULL,
      is_read BOOLEAN NOT NULL DEFAULT FALSE,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
  `);
}
