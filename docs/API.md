# PickUp (Günce) API

Base URL: `https://gunce.<subdomain>.workers.dev`. JSON in and out. Timestamps are ISO 8601 UTC
(`2026-10-12T09:30:00.000Z`). IDs are UUIDs; clients may send their own `id` on create
(offline-first). Every request except `/health` and `/v1/auth/apple` needs
`Authorization: Bearer <session token>`.

Errors: `{ "error": "<code>", "message": "…" }` with 400, 401, 403, 404, 409, 413 or 415.

## Auth

| Method | Path | Body | Notes |
| --- | --- | --- | --- |
| POST | `/v1/auth/apple` | `identity_token`, `nonce` (raw; its SHA-256 hex goes to Apple) | Returns `token`, `expires_at`, `user_id`, `new_user`. New users get İş, Hayat, Spor, Yatırım |
| POST | `/v1/auth/logout` | — | Revokes this session |
| GET | `/v1/me` | — | |
| DELETE | `/v1/me` | — | Deletes the account and all data |

Sessions last 90 days and slide forward with use.

## Areas

`GET /v1/areas` · `POST /v1/areas` (`name`, `symbol`, `color`, `sort`) ·
`PATCH /v1/areas/:id` · `DELETE /v1/areas/:id` (soft; its tasks lose the area).

## Tasks

| Method | Path | Body / query |
| --- | --- | --- |
| GET | `/v1/tasks` | `status=active,parked`, `area_id`, `parent_id` (`none` = top level), `q`, `limit` ≤ 500 |
| POST | `/v1/tasks` | `title` (required), `id`, `area_id`, `parent_id`, `details`, `next_step`, `due_at`, `remind_at`, `calendar_event_id`, `sort`, `created_via` |
| GET | `/v1/tasks/:id` | Task plus `subtasks` |
| PATCH | `/v1/tasks/:id` | Content fields only; status changes use the actions below |
| DELETE | `/v1/tasks/:id` | Soft delete, subtasks too |
| GET | `/v1/tasks/:id/events` | "İz" history, newest first |

### State changes

| Path | Body | Effect |
| --- | --- | --- |
| `POST /v1/tasks/:id/start` | `previous_note`, `previous_reason` | Atomically parks the current active task (with the note) and starts this one. Returns `task` and `parked` |
| `POST /v1/tasks/:id/park` | `note`, `reason` (`waiting`, `need_info`, `later`), `remind_at` | |
| `POST /v1/park` | same | Parks whatever is active |
| `POST /v1/tasks/:id/complete` | — | Subtasks too |
| `POST /v1/tasks/:id/reopen` | — | done/archived → inbox |
| `POST /v1/tasks/:id/archive` | — | Not for the active task |
| `POST /v1/tasks/:id/notes` | `note` | Adds a note to the history |

All accept an optional `source` (`app`, `widget`, `siri`, `share`). Claude sessions always
record `claude`.

## Sync

`GET /v1/sync?since=<server_time>` returns `areas`, `tasks` (including soft-deleted rows) and
`events` changed since the last call, plus the next `server_time`. Upsert by `id`. If
`has_more` is true, call again with the returned `server_time`.

## Devices

`PUT /v1/device-tokens` (`apns_token`, `environment`: `sandbox` | `production`) ·
`DELETE /v1/device-tokens/:token`.

## Claude connector (MCP)

Claude connects to `POST /mcp` (MCP Streamable HTTP, stateless JSON responses) with OAuth 2.1:

1. In the app, Ayarlar → Claude ile bağla calls `POST /v1/mcp/link-code` (app sessions only).
   It returns `code` (`ABCD-EFGH`, 10 minutes, single use), `expires_at` and `mcp_url`.
2. In Claude, add a custom connector with `mcp_url`. Claude reads
   `/.well-known/oauth-protected-resource` and `/.well-known/oauth-authorization-server`,
   registers at `POST /oauth/register` (redirect URIs on `claude.ai` / `claude.com` or loopback
   only) and opens `GET /oauth/authorize` (PKCE S256 required).
3. The person types the code; `POST /oauth/authorize` redirects back with an authorization code,
   which `POST /oauth/token` exchanges for a session token of kind `mcp`.

Tools: `get_overview`, `search_tasks`, `get_task`, `create_task`, `update_task`, `start_task`,
`park_task`, `complete_task`, `add_note`. They call the REST handlers with the MCP session, so
the same validation and `user_id` scoping apply, and everything is recorded with `claude` as
the source. `/mcp` rejects app tokens (403).

| Method | Path | Notes |
| --- | --- | --- |
| GET | `/v1/mcp/connections` | `label`, `created_at`, `last_used_at` of linked Claude sessions |
| DELETE | `/v1/mcp/connections` | Unlinks Claude (app sessions only) |
