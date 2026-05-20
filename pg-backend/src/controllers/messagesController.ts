import { randomUUID } from "node:crypto";

import type { Request, Response } from "express";

import { query } from "../config/db.js";

export async function listMessages(req: Request, res: Response) {
  const requestId = req.params["requestId"];
  if (!requestId) {
    res.status(400).json({ error: "requestId is required" });
    return;
  }
  const result = await query(
    "SELECT * FROM service_messages WHERE request_id = $1 ORDER BY created_at ASC",
    [requestId],
  );
  res.json({ messages: result.rows });
}

export async function createMessage(req: Request, res: Response) {
  const requestId = req.params["requestId"];
  const body = req.body as Record<string, unknown>;
  if (!requestId || typeof body["body"] !== "string") {
    res.status(400).json({ error: "requestId and body are required" });
    return;
  }

  const id = randomUUID();
  const result = await query(
    `INSERT INTO service_messages (
      id, request_id, sender_id, recipient_id, body
    ) VALUES ($1, $2, $3, $4, $5)
    RETURNING *`,
    [
      id,
      requestId,
      body["senderId"] ?? null,
      body["recipientId"] ?? null,
      body["body"],
    ],
  );
  res.status(201).json({ message: result.rows[0] });
}
