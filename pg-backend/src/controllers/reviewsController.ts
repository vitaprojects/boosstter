import { randomUUID } from "node:crypto";

import type { Request, Response } from "express";

import { query } from "../config/db.js";

export async function createReview(req: Request, res: Response) {
  const requestId = req.params["requestId"];
  const body = req.body as Record<string, unknown>;
  const rating = Number(body["rating"]);

  if (!requestId || !Number.isInteger(rating) || rating < 1 || rating > 5) {
    res.status(400).json({ error: "requestId and rating 1-5 are required" });
    return;
  }

  const id = randomUUID();
  const result = await query(
    `INSERT INTO service_reviews (
      id, request_id, reviewer_id, reviewee_id, rating, comment, is_customer_review
    ) VALUES ($1, $2, $3, $4, $5, $6, $7)
    RETURNING *`,
    [
      id,
      requestId,
      body["reviewerId"] ?? null,
      body["revieweeId"] ?? null,
      rating,
      body["comment"] ?? null,
      body["isCustomerReview"] ?? true,
    ],
  );

  res.status(201).json({ review: result.rows[0] });
}
