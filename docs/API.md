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
| POST | `/v1/tasks` | `title` (required), `id`, `area_id`, `parent_id`, `details`, `next_step`, `due_at`, `remind_at`, `calendar_event_id`, `sort`, `priority`, `recurrence`, `created_via` |
| GET | `/v1/tasks/:id` | Task plus `subtasks` |
| PATCH | `/v1/tasks/:id` | Content fields only; status changes use the actions below |
| DELETE | `/v1/tasks/:id` | Soft delete, subtasks too |
| GET | `/v1/tasks/:id/events` | "İz" history, newest first |

`priority` is the task's size: `1` ufak, `2` orta (default), `3` büyük. It decides how grand the
task's building is in Şehir. The MCP tools call it `size` (`small`, `medium`, `large`).

`recurrence` makes a task repeat: `daily`, `weekdays` or `weekly` (null = one-off). Completing a
repeating task closes the current round only: it returns to `inbox` with `completed_at` set, and
the app treats it as done until the next day (or week). Claude's tools call it `repeat`.

At most 5 top-level tasks can be `parked` at once. Parking (or a start that parks the active task)
past that returns `409 paused_limit`; resuming a parked task never counts against it.

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

## Voice notes

`POST /v1/voice` (`transcript`: what was said, up to 4000 characters, turned into text on the
device; `now`: the device's local time as ISO 8601 with its offset; optional `task_id`: the open
task the note is about; `focus`: `note` when recorded from that task's "Kaldığın yer" note, so the
note is rewritten from what was said). App sessions only. The
Worker reads the transcript with Claude against the user's open tasks and returns
`{ summary, actions }`; it stores no transcript. Each action has `kind` (`create_task`,
`add_steps`, `note`, `set_note` (replace the park note), `park`, `schedule`, `complete`, `update`), `task_id` (one of the user's
open tasks or steps) or `task_ref` (the `ref` of a `create_task` earlier in the same plan),
`title`, `steps`, `note`, `reason`, `area_id`, `priority`, `due_at`, `remind_at`. Actions that
point anywhere else are dropped. The app applies the plan through the endpoints above.
At most 300 voice requests a user per 24 hours (`429 voice_limit`); `503 voice_not_configured`
when the `ANTHROPIC_API_KEY` Worker secret is not set.

`POST /v1/voice/transcribe` (raw `audio/*` body, an .m4a recording up to 3 MB). App sessions
only; counts toward the same daily limit (300 voice requests in 24 hours). The Worker sends the
audio to ElevenLabs Scribe (`scribe_v2`, Turkish) and returns `{ text }`; it stores neither.
`503 transcribe_not_configured` without the `ELEVENLABS_API_KEY` Worker secret (the app then
keeps Apple's on-device text).

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
