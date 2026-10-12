// Small HTTP and validation helpers shared by the routes.

export interface Env {
  DB: D1Database;
  /** Comma-separated bundle IDs accepted as the `aud` of Apple identity tokens. */
  APPLE_BUNDLE_IDS: string;
}

export class HttpError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message?: string,
  ) {
    super(message ?? code);
  }
}

export function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
    },
  });
}

export function errorResponse(err: HttpError): Response {
  return json({ error: err.code, message: err.message }, err.status);
}

export async function readJson(req: Request): Promise<Record<string, unknown>> {
  const type = req.headers.get("content-type") ?? "";
  if (!type.toLowerCase().startsWith("application/json")) {
    throw new HttpError(415, "unsupported_media_type", "Send application/json");
  }
  const length = Number(req.headers.get("content-length") ?? "0");
  if (length > 64 * 1024) throw new HttpError(413, "payload_too_large");
  let body: unknown;
  try {
    body = await req.json();
  } catch {
    throw new HttpError(400, "invalid_json");
  }
  if (body === null || typeof body !== "object" || Array.isArray(body)) {
    throw new HttpError(400, "invalid_json", "Body must be a JSON object");
  }
  return body as Record<string, unknown>;
}

export const now = (): string => new Date().toISOString();

export const newId = (): string => crypto.randomUUID();

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function isUuid(v: unknown): v is string {
  return typeof v === "string" && UUID_RE.test(v);
}

// ---------------------------------------------------------------- field validators
// Each returns `undefined` when the key is absent, so PATCH can tell "not sent" from null.

export function str(
  body: Record<string, unknown>,
  key: string,
  opts: { max: number; min?: number; nullable?: boolean },
): string | null | undefined {
  if (!(key in body)) return undefined;
  const v = body[key];
  if (v === null && opts.nullable) return null;
  if (typeof v !== "string") throw new HttpError(400, "invalid_field", `${key} must be a string`);
  const trimmed = v.trim();
  const len = [...trimmed].length;
  if (len < (opts.min ?? 0) || len > opts.max) {
    throw new HttpError(400, "invalid_field", `${key} length must be ${opts.min ?? 0}–${opts.max}`);
  }
  return trimmed;
}

export function oneOf<T extends string>(
  body: Record<string, unknown>,
  key: string,
  values: readonly T[],
  nullable = false,
): T | null | undefined {
  if (!(key in body)) return undefined;
  const v = body[key];
  if (v === null && nullable) return null;
  if (typeof v !== "string" || !values.includes(v as T)) {
    throw new HttpError(400, "invalid_field", `${key} must be one of ${values.join(", ")}`);
  }
  return v as T;
}

export function timestamp(body: Record<string, unknown>, key: string): string | null | undefined {
  if (!(key in body)) return undefined;
  const v = body[key];
  if (v === null) return null;
  if (typeof v !== "string" || v.length > 40) {
    throw new HttpError(400, "invalid_field", `${key} must be an ISO 8601 date`);
  }
  const d = new Date(v);
  if (Number.isNaN(d.getTime())) {
    throw new HttpError(400, "invalid_field", `${key} must be an ISO 8601 date`);
  }
  return d.toISOString();
}

export function num(
  body: Record<string, unknown>,
  key: string,
  opts: { integer?: boolean } = {},
): number | undefined {
  if (!(key in body)) return undefined;
  const v = body[key];
  if (typeof v !== "number" || !Number.isFinite(v) || (opts.integer && !Number.isInteger(v))) {
    throw new HttpError(400, "invalid_field", `${key} must be a number`);
  }
  return v;
}

export function uuidField(body: Record<string, unknown>, key: string): string | null | undefined {
  if (!(key in body)) return undefined;
  const v = body[key];
  if (v === null) return null;
  if (!isUuid(v)) throw new HttpError(400, "invalid_field", `${key} must be a UUID`);
  return v.toLowerCase();
}

export const TASK_STATUSES = ["inbox", "active", "parked", "done", "archived"] as const;
export const PARK_REASONS = ["waiting", "need_info", "later"] as const;
export const SOURCES = ["app", "claude", "widget", "siri", "share"] as const;
export type ParkReason = (typeof PARK_REASONS)[number];
export type Source = (typeof SOURCES)[number];
