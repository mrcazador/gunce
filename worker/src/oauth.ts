// OAuth 2.1 for the Claude connector (remote MCP).
//
// Claude registers itself (dynamic client registration), sends the person to /oauth/authorize,
// and the person types a short pairing code from the app (Ayarlar → Claude). That proves which
// PickUp account to link without a web login. The token endpoint then mints an ordinary session
// of kind 'mcp', so the REST and MCP layers share one auth path. PKCE (S256) is required.

import { createSession, randomToken, type Session, SESSION_DAYS, sha256Hex } from "./auth";
import { type Env, HttpError, json, now } from "./http";

const LINK_CODE_MINUTES = 10;
const AUTH_CODE_MINUTES = 5;
/** No 0/O or 1/I, so codes are easy to read off a phone. */
const ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

const minutesFromNow = (m: number) => new Date(Date.now() + m * 60_000).toISOString();

function base64url(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function pkceChallenge(verifier: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
  return base64url(new Uint8Array(digest));
}

function normalizeCode(raw: string): string {
  return raw.toUpperCase().replace(/[^A-Z0-9]/g, "");
}

function oauthError(error: string, description: string, status = 400): Response {
  return json({ error, error_description: description }, status);
}

// ================================================================= app side

/** POST /v1/mcp/link-code — a pairing code for the Claude connector, shown in the app. */
export async function createLinkCode(env: Env, s: Session, url: URL): Promise<Response> {
  if (s.kind !== "app") throw new HttpError(403, "forbidden");
  await purgeExpired(env);
  const bytes = crypto.getRandomValues(new Uint8Array(8));
  const code = [...bytes].map((b) => ALPHABET[b & 31]).join("");
  const expiresAt = minutesFromNow(LINK_CODE_MINUTES);
  await env.DB.prepare(
    `INSERT INTO mcp_link_codes (code_hash, user_id, expires_at) VALUES (?, ?, ?)
     ON CONFLICT (user_id) DO UPDATE SET code_hash = excluded.code_hash, expires_at = excluded.expires_at`,
  )
    .bind(await sha256Hex(code), s.userId, expiresAt)
    .run();
  return json(
    { code: `${code.slice(0, 4)}-${code.slice(4)}`, expires_at: expiresAt, mcp_url: `${url.origin}/mcp` },
    201,
  );
}

/** GET /v1/mcp/connections — the Claude sessions linked to this account. */
export async function listConnections(env: Env, s: Session): Promise<Response> {
  const { results } = await env.DB.prepare(
    "SELECT label, created_at, last_used_at FROM sessions WHERE user_id = ? AND kind = 'mcp' ORDER BY created_at DESC",
  )
    .bind(s.userId)
    .all();
  return json({ connections: results });
}

/** DELETE /v1/mcp/connections — unlinks Claude: revokes every MCP session and pending code. */
export async function deleteConnections(env: Env, s: Session): Promise<Response> {
  if (s.kind !== "app") throw new HttpError(403, "forbidden");
  await env.DB.batch([
    env.DB.prepare("DELETE FROM sessions WHERE user_id = ? AND kind = 'mcp'").bind(s.userId),
    env.DB.prepare("DELETE FROM oauth_codes WHERE user_id = ?").bind(s.userId),
    env.DB.prepare("DELETE FROM mcp_link_codes WHERE user_id = ?").bind(s.userId),
  ]);
  return new Response(null, { status: 204 });
}

// ================================================================= metadata

/** RFC 9728: where Claude learns which authorization server protects /mcp. */
export function protectedResourceMetadata(url: URL): Response {
  return json({
    resource: `${url.origin}/mcp`,
    authorization_servers: [url.origin],
    bearer_methods_supported: ["header"],
    resource_name: "PickUp",
  });
}

/** RFC 8414 authorization server metadata. */
export function authorizationServerMetadata(url: URL): Response {
  const o = url.origin;
  return json({
    issuer: o,
    authorization_endpoint: `${o}/oauth/authorize`,
    token_endpoint: `${o}/oauth/token`,
    registration_endpoint: `${o}/oauth/register`,
    response_types_supported: ["code"],
    grant_types_supported: ["authorization_code"],
    code_challenge_methods_supported: ["S256"],
    token_endpoint_auth_methods_supported: ["none"],
    scopes_supported: ["tasks"],
  });
}

// ================================================================= registration

/** Claude's web callback, and loopback redirects for desktop and CLI clients. */
function allowedRedirect(raw: unknown): raw is string {
  if (typeof raw !== "string" || raw.length > 500) return false;
  let u: URL;
  try {
    u = new URL(raw);
  } catch {
    return false;
  }
  if (u.hash) return false;
  if (u.protocol === "https:") return u.hostname === "claude.ai" || u.hostname === "claude.com";
  if (u.protocol === "http:") return u.hostname === "localhost" || u.hostname === "127.0.0.1";
  return false;
}

/** POST /oauth/register (RFC 7591) — public clients only. */
export async function register(req: Request, env: Env): Promise<Response> {
  let body: Record<string, unknown>;
  try {
    body = (await req.json()) as Record<string, unknown>;
  } catch {
    return oauthError("invalid_client_metadata", "Body must be JSON");
  }
  const uris = body?.redirect_uris;
  if (!Array.isArray(uris) || uris.length === 0 || uris.length > 5 || !uris.every(allowedRedirect)) {
    return oauthError("invalid_redirect_uri", "Only Claude callback URLs are accepted");
  }
  const name = typeof body.client_name === "string" ? body.client_name.slice(0, 100) : "Claude";
  const clientId = crypto.randomUUID();
  await env.DB.prepare("INSERT INTO oauth_clients (client_id, client_name, redirect_uris) VALUES (?, ?, ?)")
    .bind(clientId, name, JSON.stringify(uris))
    .run();
  return json(
    {
      client_id: clientId,
      client_id_issued_at: Math.floor(Date.now() / 1000),
      client_name: name,
      redirect_uris: uris,
      grant_types: ["authorization_code"],
      response_types: ["code"],
      token_endpoint_auth_method: "none",
    },
    201,
  );
}

// ================================================================= authorize

interface AuthorizeParams {
  clientId: string;
  clientName: string;
  redirectUri: string;
  state: string;
  challenge: string;
}

/** Validates the request. Errors here are shown as a page, never redirected. */
async function readAuthorize(env: Env, get: (k: string) => string | null): Promise<AuthorizeParams> {
  const clientId = get("client_id") ?? "";
  const redirectUri = get("redirect_uri") ?? "";
  const client = await env.DB.prepare("SELECT client_name, redirect_uris FROM oauth_clients WHERE client_id = ?")
    .bind(clientId)
    .first<{ client_name: string | null; redirect_uris: string }>();
  if (!client) throw new HttpError(400, "Bilinmeyen uygulama. Claude'da bağlantıyı yeniden başlat.");
  if (!(JSON.parse(client.redirect_uris) as string[]).includes(redirectUri)) {
    throw new HttpError(400, "Geçersiz yönlendirme adresi.");
  }
  const challenge = get("code_challenge") ?? "";
  if (get("response_type") !== "code" || get("code_challenge_method") !== "S256" || !/^[A-Za-z0-9_-]{43,128}$/.test(challenge)) {
    throw new HttpError(400, "Geçersiz yetkilendirme isteği.");
  }
  const state = (get("state") ?? "").slice(0, 500);
  return { clientId, clientName: client.client_name ?? "Claude", redirectUri, state, challenge };
}

/** GET /oauth/authorize — asks for the pairing code from the app. */
export async function authorizePage(url: URL, env: Env): Promise<Response> {
  try {
    const p = await readAuthorize(env, (k) => url.searchParams.get(k));
    return page(form(p, null));
  } catch (err) {
    if (err instanceof HttpError) return page(`<p class="error">${escapeHtml(err.code)}</p>`, 400);
    throw err;
  }
}

/** POST /oauth/authorize — checks the pairing code and redirects back to Claude with a code. */
export async function authorizeSubmit(req: Request, env: Env): Promise<Response> {
  const formData = await req.formData();
  const field = (k: string) => {
    const v = formData.get(k);
    return typeof v === "string" ? v : null;
  };
  let p: AuthorizeParams;
  try {
    p = await readAuthorize(env, field);
  } catch (err) {
    if (err instanceof HttpError) return page(`<p class="error">${escapeHtml(err.code)}</p>`, 400);
    throw err;
  }

  const code = normalizeCode(field("pairing_code") ?? "");
  // Single use: the row is deleted as it is read.
  const link = code.length === 8
    ? await env.DB.prepare("DELETE FROM mcp_link_codes WHERE code_hash = ? RETURNING user_id, expires_at")
        .bind(await sha256Hex(code))
        .first<{ user_id: string; expires_at: string }>()
    : null;
  if (!link || Date.parse(link.expires_at) <= Date.now()) {
    return page(form(p, "Kod geçersiz ya da süresi dolmuş. Uygulamada yeni bir kod oluştur."), 400);
  }

  const authCode = randomToken();
  await env.DB.prepare(
    `INSERT INTO oauth_codes (code_hash, user_id, client_id, redirect_uri, code_challenge, expires_at)
     VALUES (?, ?, ?, ?, ?, ?)`,
  )
    .bind(await sha256Hex(authCode), link.user_id, p.clientId, p.redirectUri, p.challenge, minutesFromNow(AUTH_CODE_MINUTES))
    .run();

  const target = new URL(p.redirectUri);
  target.searchParams.set("code", authCode);
  if (p.state) target.searchParams.set("state", p.state);
  target.searchParams.set("iss", new URL(req.url).origin);
  return new Response(null, { status: 302, headers: { location: target.toString(), "cache-control": "no-store" } });
}

// ================================================================= token

/** POST /oauth/token — authorization_code grant with PKCE. */
export async function token(req: Request, env: Env): Promise<Response> {
  const type = req.headers.get("content-type") ?? "";
  const params = type.includes("application/json")
    ? new URLSearchParams(Object.entries((await req.json().catch(() => ({}))) as Record<string, string>))
    : new URLSearchParams(await req.text());
  if (params.get("grant_type") !== "authorization_code") {
    return oauthError("unsupported_grant_type", "Only authorization_code is supported");
  }
  const code = params.get("code") ?? "";
  const verifier = params.get("code_verifier") ?? "";
  if (!/^gn_[A-Za-z0-9_-]{43}$/.test(code) || !/^[A-Za-z0-9._~-]{43,128}$/.test(verifier)) {
    return oauthError("invalid_grant", "Invalid code or verifier");
  }
  const row = await env.DB.prepare(
    "DELETE FROM oauth_codes WHERE code_hash = ? RETURNING user_id, client_id, redirect_uri, code_challenge, expires_at",
  )
    .bind(await sha256Hex(code))
    .first<{ user_id: string; client_id: string; redirect_uri: string; code_challenge: string; expires_at: string }>();
  if (
    !row ||
    Date.parse(row.expires_at) <= Date.now() ||
    row.client_id !== params.get("client_id") ||
    row.redirect_uri !== params.get("redirect_uri") ||
    (await pkceChallenge(verifier)) !== row.code_challenge
  ) {
    return oauthError("invalid_grant", "Code is invalid, expired or already used");
  }
  const client = await env.DB.prepare("SELECT client_name FROM oauth_clients WHERE client_id = ?")
    .bind(row.client_id)
    .first<{ client_name: string | null }>();
  const session = await createSession(env, row.user_id, "mcp", client?.client_name ?? "Claude");
  return json({
    access_token: session.token,
    token_type: "Bearer",
    expires_in: SESSION_DAYS * 86_400,
    scope: "tasks",
  });
}

/** Old pairing codes and authorization codes. Called opportunistically, cheap with the indexes. */
export async function purgeExpired(env: Env): Promise<void> {
  const stamp = now();
  await env.DB.batch([
    env.DB.prepare("DELETE FROM mcp_link_codes WHERE expires_at <= ?").bind(stamp),
    env.DB.prepare("DELETE FROM oauth_codes WHERE expires_at <= ?").bind(stamp),
  ]);
}

// ================================================================= page

function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);
}

function form(p: AuthorizeParams, error: string | null): string {
  const hidden = (name: string, value: string) =>
    `<input type="hidden" name="${name}" value="${escapeHtml(value)}">`;
  return `
    <p><strong>${escapeHtml(p.clientName)}</strong> PickUp görevlerine erişmek istiyor: görevleri okuyabilir,
    ekleyebilir, başlatıp park edebilir ve bitirebilir.</p>
    <p class="hint">PickUp'ta <b>Ayarlar → Claude ile bağla</b>'ya dokun ve gösterilen kodu buraya yaz.</p>
    <form method="post" action="/oauth/authorize">
      ${hidden("client_id", p.clientId)}
      ${hidden("redirect_uri", p.redirectUri)}
      ${hidden("state", p.state)}
      ${hidden("code_challenge", p.challenge)}
      ${hidden("code_challenge_method", "S256")}
      ${hidden("response_type", "code")}
      <label for="code">Bağlantı kodu</label>
      <input id="code" name="pairing_code" autocomplete="one-time-code" autocapitalize="characters"
        spellcheck="false" inputmode="text" maxlength="12" placeholder="ABCD-EFGH" required autofocus>
      ${error ? `<p class="error" role="alert">${escapeHtml(error)}</p>` : ""}
      <button type="submit">Bağla</button>
    </form>`;
}

function page(body: string, status = 200): Response {
  const html = `<!doctype html>
<html lang="tr"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>PickUp'ı Claude'a bağla</title>
<style>
  :root { color-scheme: light dark; --fg: #111; --muted: #666; --bg: #fff; --field: #f2f2f7; --err: #c62828; }
  @media (prefers-color-scheme: dark) { :root { --fg: #f5f5f5; --muted: #a0a0a0; --bg: #000; --field: #1c1c1e; --err: #ff6b6b; } }
  body { font: 17px/1.45 -apple-system, system-ui, sans-serif; color: var(--fg); background: var(--bg); margin: 0; }
  main { max-width: 420px; margin: 0 auto; padding: 48px 20px; }
  h1 { font-size: 28px; margin: 0 0 16px; }
  .hint { color: var(--muted); }
  label { display: block; font-weight: 600; margin: 24px 0 8px; }
  input[name=pairing_code] { width: 100%; box-sizing: border-box; font: 600 24px ui-monospace, monospace; letter-spacing: 2px;
    padding: 12px 14px; border-radius: 12px; border: 0; background: var(--field); color: var(--fg); text-transform: uppercase; }
  button { width: 100%; min-height: 50px; margin-top: 20px; border: 0; border-radius: 25px; font: 600 17px -apple-system, system-ui, sans-serif;
    background: var(--fg); color: var(--bg); }
  .error { color: var(--err); }
</style></head>
<body><main><h1>PickUp'ı Claude'a bağla</h1>${body}</main></body></html>`;
  return new Response(html, {
    status,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
      "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'",
      "x-frame-options": "DENY",
      "referrer-policy": "no-referrer",
      "x-content-type-options": "nosniff",
    },
  });
}
