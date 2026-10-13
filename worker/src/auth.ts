// Sign in with Apple → opaque session tokens.
//
// The app sends Apple's identity token plus the raw nonce it hashed into the Apple request.
// We verify the token against Apple's public keys, find or create the user, and return a
// random session token. Only the token's SHA-256 hash is stored, so a database leak does not
// leak usable sessions.

import { createRemoteJWKSet, jwtVerify } from "jose";
import { type Env, HttpError, json, newId, now, readJson } from "./http";

const APPLE_ISSUER = "https://appleid.apple.com";
const appleKeys = createRemoteJWKSet(new URL("https://appleid.apple.com/auth/keys"), {
  cooldownDuration: 30_000,
  cacheMaxAge: 6 * 60 * 60 * 1000,
});

export const SESSION_DAYS = 90;
/** Only refresh last_used/expiry at most once per hour to keep writes low. */
const TOUCH_INTERVAL_MS = 60 * 60 * 1000;

export interface Session {
  userId: string;
  kind: "app" | "mcp";
}

const DEFAULT_AREAS = [
  { name: "İş", symbol: "briefcase", color: "indigo" },
  { name: "Hayat", symbol: "heart", color: "pink" },
  { name: "Spor", symbol: "figure.run", color: "orange" },
  { name: "Yatırım", symbol: "chart.line.uptrend.xyaxis", color: "green" },
];

export async function sha256Hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export function randomToken(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return "gn_" + btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function expiry(): string {
  return new Date(Date.now() + SESSION_DAYS * 86_400_000).toISOString();
}

/** Constant-time-ish string compare for the nonce check. */
function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

async function verifyAppleToken(env: Env, identityToken: string, rawNonce: string) {
  const audiences = env.APPLE_BUNDLE_IDS.split(",").map((s) => s.trim()).filter(Boolean);
  if (audiences.length === 0) throw new HttpError(500, "server_misconfigured");
  try {
    const { payload } = await jwtVerify(identityToken, appleKeys, {
      issuer: APPLE_ISSUER,
      audience: audiences,
      algorithms: ["RS256"],
      clockTolerance: 60,
    });
    const expectedNonce = await sha256Hex(rawNonce);
    if (typeof payload.nonce !== "string" || !safeEqual(payload.nonce, expectedNonce)) {
      throw new Error("nonce mismatch");
    }
    if (typeof payload.sub !== "string" || payload.sub.length === 0 || payload.sub.length > 255) {
      throw new Error("missing sub");
    }
    return payload.sub;
  } catch {
    throw new HttpError(401, "invalid_apple_token");
  }
}

export async function createSession(env: Env, userId: string, kind: Session["kind"], label: string | null) {
  const token = randomToken();
  const expiresAt = expiry();
  await env.DB.prepare(
    "INSERT INTO sessions (token_hash, user_id, kind, label, expires_at) VALUES (?, ?, ?, ?, ?)",
  )
    .bind(await sha256Hex(token), userId, kind, label, expiresAt)
    .run();
  return { token, expires_at: expiresAt };
}

/** POST /v1/auth/apple { identity_token, nonce } */
export async function signInWithApple(req: Request, env: Env): Promise<Response> {
  const body = await readJson(req);
  const identityToken = body.identity_token;
  const nonce = body.nonce;
  if (typeof identityToken !== "string" || identityToken.length > 8192) {
    throw new HttpError(400, "invalid_field", "identity_token is required");
  }
  if (typeof nonce !== "string" || nonce.length < 16 || nonce.length > 256) {
    throw new HttpError(400, "invalid_field", "nonce is required");
  }
  const appleSub = await verifyAppleToken(env, identityToken, nonce);

  let user = await env.DB.prepare("SELECT id FROM users WHERE apple_sub = ?")
    .bind(appleSub)
    .first<{ id: string }>();

  let created = false;
  if (!user) {
    const id = newId();
    const stamp = now();
    const stmts = [
      env.DB.prepare("INSERT INTO users (id, apple_sub, created_at) VALUES (?, ?, ?) ON CONFLICT (apple_sub) DO NOTHING")
        .bind(id, appleSub, stamp),
      ...DEFAULT_AREAS.map((a, i) =>
        env.DB.prepare(
          `INSERT INTO areas (id, user_id, name, symbol, color, sort, created_at, updated_at)
           SELECT ?, ?, ?, ?, ?, ?, ?, ? WHERE EXISTS (SELECT 1 FROM users WHERE id = ? AND apple_sub = ?)`,
        ).bind(newId(), id, a.name, a.symbol, a.color, i, stamp, stamp, id, appleSub),
      ),
    ];
    await env.DB.batch(stmts);
    user = await env.DB.prepare("SELECT id FROM users WHERE apple_sub = ?")
      .bind(appleSub)
      .first<{ id: string }>();
    if (!user) throw new HttpError(500, "user_create_failed");
    created = user.id === id;
  }

  const session = await createSession(env, user.id, "app", null);
  return json({ ...session, user_id: user.id, new_user: created }, created ? 201 : 200);
}

/** Resolve the bearer token on a request, or throw 401. */
export async function authenticate(req: Request, env: Env): Promise<Session & { tokenHash: string }> {
  const header = req.headers.get("authorization") ?? "";
  const match = /^Bearer (gn_[A-Za-z0-9_-]{43})$/.exec(header);
  if (!match) throw new HttpError(401, "unauthorized");
  const tokenHash = await sha256Hex(match[1]);
  const row = await env.DB.prepare(
    "SELECT user_id, kind, last_used_at, expires_at FROM sessions WHERE token_hash = ?",
  )
    .bind(tokenHash)
    .first<{ user_id: string; kind: Session["kind"]; last_used_at: string; expires_at: string }>();
  if (!row || Date.parse(row.expires_at) <= Date.now()) throw new HttpError(401, "unauthorized");

  if (Date.now() - Date.parse(row.last_used_at) > TOUCH_INTERVAL_MS) {
    await env.DB.prepare("UPDATE sessions SET last_used_at = ?, expires_at = ? WHERE token_hash = ?")
      .bind(now(), expiry(), tokenHash)
      .run();
  }
  return { userId: row.user_id, kind: row.kind, tokenHash };
}

/** POST /v1/auth/logout — revokes the calling session. */
export async function logout(env: Env, tokenHash: string): Promise<Response> {
  await env.DB.prepare("DELETE FROM sessions WHERE token_hash = ?").bind(tokenHash).run();
  return new Response(null, { status: 204 });
}

/** DELETE /v1/me — deletes the account and all its data (App Store requirement). */
export async function deleteAccount(env: Env, userId: string): Promise<Response> {
  // Children first: D1 enforces foreign keys, but explicit deletes keep this independent of it.
  await env.DB.batch([
    env.DB.prepare("DELETE FROM task_events WHERE user_id = ?").bind(userId),
    env.DB.prepare("UPDATE tasks SET parent_id = NULL WHERE user_id = ?").bind(userId),
    env.DB.prepare("DELETE FROM tasks WHERE user_id = ?").bind(userId),
    env.DB.prepare("DELETE FROM areas WHERE user_id = ?").bind(userId),
    env.DB.prepare("DELETE FROM device_tokens WHERE user_id = ?").bind(userId),
    env.DB.prepare("DELETE FROM sessions WHERE user_id = ?").bind(userId),
    env.DB.prepare("DELETE FROM users WHERE id = ?").bind(userId),
  ]);
  return new Response(null, { status: 204 });
}
