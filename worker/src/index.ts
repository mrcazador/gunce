// Günce API — Cloudflare Worker + D1.

import { authenticate, deleteAccount, logout, signInWithApple } from "./auth";
import { type Env, errorResponse, HttpError, isUuid, json } from "./http";
import * as t from "./tasks";

type Handler = (ctx: {
  req: Request;
  url: URL;
  env: Env;
  params: string[];
}) => Promise<Response>;

interface Route {
  method: string;
  pattern: RegExp;
  auth: boolean;
  handler: Handler;
}

const ID = "([0-9a-fA-F-]{36})";
const routes: Route[] = [];

function route(method: string, path: string, auth: boolean, handler: Handler) {
  routes.push({ method, pattern: new RegExp(`^${path.replace(/:id/g, ID)}$`), auth, handler });
}

// Authenticated handlers receive the session through a closure set per request.
type Authed = (ctx: Parameters<Handler>[0], s: Awaited<ReturnType<typeof authenticate>>) => Promise<Response>;
const authed = (method: string, path: string, h: Authed) =>
  route(method, path, true, async (ctx) => h(ctx, await authenticate(ctx.req, ctx.env)));

// ---------------------------------------------------------------- public
route("GET", "/health", false, async () => json({ ok: true }));
route("POST", "/v1/auth/apple", false, ({ req, env }) => signInWithApple(req, env));

// ---------------------------------------------------------------- account
authed("GET", "/v1/me", async ({ env }, s) => {
  const user = await env.DB.prepare("SELECT id, created_at FROM users WHERE id = ?").bind(s.userId).first();
  return json({ user, session_kind: s.kind });
});
authed("POST", "/v1/auth/logout", ({ env }, s) => logout(env, s.tokenHash));
authed("DELETE", "/v1/me", ({ env }, s) => {
  if (s.kind !== "app") throw new HttpError(403, "forbidden");
  return deleteAccount(env, s.userId);
});

// ---------------------------------------------------------------- areas
authed("GET", "/v1/areas", ({ env }, s) => t.listAreas(env, s));
authed("POST", "/v1/areas", ({ req, env }, s) => t.createArea(req, env, s));
authed("PATCH", "/v1/areas/:id", ({ req, env, params }, s) => t.updateArea(req, env, s, params[0]));
authed("DELETE", "/v1/areas/:id", ({ env, params }, s) => t.deleteArea(env, s, params[0]));

// ---------------------------------------------------------------- tasks
authed("GET", "/v1/tasks", ({ url, env }, s) => t.listTasks(url, env, s));
authed("POST", "/v1/tasks", ({ req, env }, s) => t.createTask(req, env, s));
authed("GET", "/v1/tasks/:id", ({ env, params }, s) => t.readTask(env, s, params[0]));
authed("PATCH", "/v1/tasks/:id", ({ req, env, params }, s) => t.updateTask(req, env, s, params[0]));
authed("DELETE", "/v1/tasks/:id", ({ env, params }, s) => t.deleteTask(env, s, params[0]));
authed("POST", "/v1/tasks/:id/start", ({ req, env, params }, s) => t.startTask(req, env, s, params[0]));
authed("POST", "/v1/tasks/:id/park", ({ req, env, params }, s) => t.parkTask(req, env, s, params[0]));
authed("POST", "/v1/park", ({ req, env }, s) => t.parkTask(req, env, s, null));
authed("POST", "/v1/tasks/:id/complete", ({ req, env, params }, s) => t.completeTask(req, env, s, params[0]));
authed("POST", "/v1/tasks/:id/reopen", ({ req, env, params }, s) => t.reopenTask(req, env, s, params[0]));
authed("POST", "/v1/tasks/:id/archive", ({ env, params }, s) => t.archiveTask(env, s, params[0]));
authed("POST", "/v1/tasks/:id/notes", ({ req, env, params }, s) => t.addNote(req, env, s, params[0]));
authed("GET", "/v1/tasks/:id/events", ({ env, params }, s) => t.listEvents(env, s, params[0]));

// ---------------------------------------------------------------- sync and devices
authed("GET", "/v1/sync", ({ url, env }, s) => t.sync(url, env, s));
authed("PUT", "/v1/device-tokens", ({ req, env }, s) => t.putDeviceToken(req, env, s));
authed("DELETE", "/v1/device-tokens/([0-9a-fA-F]{1,200})", ({ env, params }, s) =>
  t.deleteDeviceToken(env, s, params[0]),
);

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    try {
      let pathMatched = false;
      for (const r of routes) {
        const m = r.pattern.exec(url.pathname);
        if (!m) continue;
        pathMatched = true;
        if (r.method !== req.method) continue;
        const params = m.slice(1).map((p) => (isUuid(p) ? p.toLowerCase() : p));
        return await r.handler({ req, url, env, params });
      }
      throw pathMatched ? new HttpError(405, "method_not_allowed") : new HttpError(404, "not_found");
    } catch (err) {
      if (err instanceof HttpError) return errorResponse(err);
      console.error("unhandled", err instanceof Error ? err.message : err);
      return json({ error: "internal_error" }, 500);
    }
  },
} satisfies ExportedHandler<Env>;
