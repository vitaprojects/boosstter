import type { NextFunction, Request, Response } from "express";

import { config } from "../config/env.js";

function decodeBasicAuth(header: string) {
  const [scheme, token] = header.split(" ");
  if (scheme !== "Basic" || !token) return null;

  const decoded = Buffer.from(token, "base64").toString("utf8");
  const separatorIndex = decoded.indexOf(":");
  if (separatorIndex < 0) return null;

  return {
    username: decoded.slice(0, separatorIndex),
    password: decoded.slice(separatorIndex + 1),
  };
}

export function requireAdmin(req: Request, res: Response, next: NextFunction) {
  const credentials = decodeBasicAuth(req.header("authorization") ?? "");
  const isValid =
    credentials?.username === config.tempAdminUsername &&
    credentials.password === config.tempAdminPassword;

  if (!isValid) {
    res.setHeader("WWW-Authenticate", 'Basic realm="Boosstter Demo Admin"');
    res.status(401).json({
      error: "Unauthorized",
      message: "Use the temporary demo admin username and password.",
    });
    return;
  }

  next();
}
