// Areas, tasks, history and device tokens. Every statement is scoped to `user_id = ?`.

import type { Session } from "./auth";
import {
  type Env,
  HttpError,
  json,
  newId,
  now,
  num,
  oneOf,
  PARK_REASONS,
  type ParkReason,
  readJson,
  type Source,
  SOURCES,
  str,
  timestamp,
  uuidField,
} from "./http";

type Row = Record<string, unknown>;

const TASK_COLUMNS = `id, area_id, parent_id, title, details, status, next_step, park_note, park_reason,
  parked_at, started_at, due_at, remind_at, calendar_event_id, sort, created_via,
  created_at, updated_at, completed_at, deleted_at`;
const AREA_COLUMNS = "id, name, symbol, color, sort, created_at, updated_at, deleted_at";
const EVENT_COLUMNS = "id, task_id, kind, note, reason, duration_seconds, source, occurred_at";

/** Sessions minted for Claude always write `claude` as the source. */
function sourceFor(session: Session, body: Row, key = "source"): Source {
  if (session.kind === "mcp") return "claude";
  return oneOf(body, key, SOURCES) ?? "app";
}

/** Map SQLite constraint errors to HTTP errors. */
export function mapDbError(err: unknown): never {
  const msg = err instanceof Error ? err.message : String(err);
  if (msg.includes("tasks_one_active_per_user") || msg.includes("UNIQUE constraint failed: tasks.user_id")) {
    throw new HttpError(409, "another_task_active", "Use /start to switch tasks");
  }
  if (msg.includes("UNIQUE constraint failed")) throw new HttpError(409, "conflict");
  if (msg.includes("does not belong to user")) throw new HttpError(400, "invalid_reference");
  if (msg.includes("cannot be its own parent")) throw new HttpError(400, "invalid_reference");
  if (msg.includes("CHECK constraint failed")) throw new HttpError(400, "invalid_field");
  if (msg.includes("FOREIGN KEY constraint failed")) throw new HttpError(400, "invalid_reference");
  throw err;
}

async function getTask(env: Env, userId: string, id: string): Promise<Row> {
  const row = await env.DB.prepare(`SELECT ${TASK_COLUMNS} FROM tasks WHERE id = ? AND user_id = ?`)
    .bind(id, userId)
    .first<Row>();
  if (!row || row.deleted_at) throw new HttpError(404, "task_not_found");
  return row;
}

// ================================================================= areas

export async function listAreas(env: Env, s: Session): Promise<Response> {
  const { results } = await env.DB.prepare(
    `SELECT ${AREA_COLUMNS} FROM areas WHERE user_id = ? AND deleted_at IS NULL ORDER BY sort, name`,
  )
    .bind(s.userId)
    .all();
  return json({ areas: results });
}

export async function createArea(req: Request, env: Env, s: Session): Promise<Response> {
  const body = await readJson(req);
  const id = uuidField(body, "id") ?? newId();
  const name = str(body, "name", { min: 1, max: 40 });
  if (!name) throw new HttpError(400, "invalid_field", "name is required");
  const symbol = str(body, "symbol", { min: 1, max: 80 }) ?? "circle";
  const color = str(body, "color", { min: 1, max: 30 }) ?? "gray";
  const sort = num(body, "sort", { integer: true }) ?? 0;
  const stamp = now();
  try {
    // Re-creating an area with the name of a deleted one revives it.
    const row = await env.DB.prepare(
      `INSERT INTO areas (id, user_id, name, symbol, color, sort, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT (user_id, name) DO UPDATE SET
         symbol = excluded.symbol, color = excluded.color, sort = excluded.sort,
         updated_at = excluded.updated_at, deleted_at = NULL
       WHERE areas.deleted_at IS NOT NULL
       RETURNING ${AREA_COLUMNS}`,
    )
      .bind(id, s.userId, name, symbol, color, sort, stamp, stamp)
      .first<Row>();
    if (!row) throw new HttpError(409, "area_exists");
    return json({ area: row }, 201);
  } catch (err) {
    if (err instanceof HttpError) throw err;
    mapDbError(err);
  }
}

export async function updateArea(req: Request, env: Env, s: Session, id: string): Promise<Response> {
  const body = await readJson(req);
  const sets: string[] = [];
  const binds: unknown[] = [];
  const name = str(body, "name", { min: 1, max: 40 });
  const symbol = str(body, "symbol", { min: 1, max: 80 });
  const color = str(body, "color", { min: 1, max: 30 });
  const sort = num(body, "sort", { integer: true });
  if (name !== undefined) sets.push("name = ?"), binds.push(name);
  if (symbol !== undefined) sets.push("symbol = ?"), binds.push(symbol);
  if (color !== undefined) sets.push("color = ?"), binds.push(color);
  if (sort !== undefined) sets.push("sort = ?"), binds.push(sort);
  if (sets.length === 0) throw new HttpError(400, "nothing_to_update");
  sets.push("updated_at = ?");
  binds.push(now());
  try {
    const row = await env.DB.prepare(
      `UPDATE areas SET ${sets.join(", ")} WHERE id = ? AND user_id = ? AND deleted_at IS NULL
       RETURNING ${AREA_COLUMNS}`,
    )
      .bind(...binds, id, s.userId)
      .first<Row>();
    if (!row) throw new HttpError(404, "area_not_found");
    return json({ area: row });
  } catch (err) {
    if (err instanceof HttpError) throw err;
    mapDbError(err);
  }
}

export async function deleteArea(env: Env, s: Session, id: string): Promise<Response> {
  const stamp = now();
  const [, res] = await env.DB.batch([
    env.DB.prepare(
      "UPDATE tasks SET area_id = NULL, updated_at = ? WHERE area_id = ? AND user_id = ?",
    ).bind(stamp, id, s.userId),
    env.DB.prepare(
      "UPDATE areas SET deleted_at = ?, updated_at = ? WHERE id = ? AND user_id = ? AND deleted_at IS NULL",
    ).bind(stamp, stamp, id, s.userId),
  ]);
  if (!res.meta.changes) throw new HttpError(404, "area_not_found");
  return new Response(null, { status: 204 });
}

// ================================================================= tasks

export async function listTasks(url: URL, env: Env, s: Session): Promise<Response> {
  const where = ["user_id = ?", "deleted_at IS NULL"];
  const binds: unknown[] = [s.userId];

  const status = url.searchParams.get("status");
  if (status) {
    const list = status.split(",").filter((v) => ["inbox", "active", "parked", "done", "archived"].includes(v));
    if (list.length === 0) throw new HttpError(400, "invalid_field", "status");
    where.push(`status IN (${list.map(() => "?").join(",")})`);
    binds.push(...list);
  }
  const areaId = url.searchParams.get("area_id");
  if (areaId) where.push("area_id = ?"), binds.push(areaId);
  const parentId = url.searchParams.get("parent_id");
  if (parentId === "none") where.push("parent_id IS NULL");
  else if (parentId) where.push("parent_id = ?"), binds.push(parentId);
  const q = url.searchParams.get("q");
  if (q) {
    if (q.length > 200) throw new HttpError(400, "invalid_field", "q");
    where.push("(title LIKE ? ESCAPE '\\' OR details LIKE ? ESCAPE '\\' OR park_note LIKE ? ESCAPE '\\')");
    const like = `%${q.replace(/[\\%_]/g, (c) => "\\" + c)}%`;
    binds.push(like, like, like);
  }
  const limit = Math.min(Math.max(Number(url.searchParams.get("limit") ?? 200) || 200, 1), 500);

  const { results } = await env.DB.prepare(
    `SELECT ${TASK_COLUMNS} FROM tasks WHERE ${where.join(" AND ")}
     ORDER BY CASE status WHEN 'active' THEN 0 WHEN 'parked' THEN 1 WHEN 'inbox' THEN 2 ELSE 3 END,
              sort, updated_at DESC
     LIMIT ?`,
  )
    .bind(...binds, limit)
    .all();
  return json({ tasks: results });
}

export async function readTask(env: Env, s: Session, id: string): Promise<Response> {
  const task = await getTask(env, s.userId, id);
  const { results: subtasks } = await env.DB.prepare(
    `SELECT ${TASK_COLUMNS} FROM tasks WHERE parent_id = ? AND user_id = ? AND deleted_at IS NULL ORDER BY sort, created_at`,
  )
    .bind(id, s.userId)
    .all();
  return json({ task, subtasks });
}

export async function createTask(req: Request, env: Env, s: Session): Promise<Response> {
  const body = await readJson(req);
  const id = uuidField(body, "id") ?? newId();
  const title = str(body, "title", { min: 1, max: 500 });
  if (!title) throw new HttpError(400, "invalid_field", "title is required");
  const status = oneOf(body, "status", ["inbox"] as const) ?? "inbox";
  const stamp = now();
  try {
    const row = await env.DB.prepare(
      `INSERT INTO tasks (id, user_id, area_id, parent_id, title, details, status, next_step,
         due_at, remind_at, calendar_event_id, sort, created_via, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
       RETURNING ${TASK_COLUMNS}`,
    )
      .bind(
        id,
        s.userId,
        uuidField(body, "area_id") ?? null,
        uuidField(body, "parent_id") ?? null,
        title,
        str(body, "details", { max: 10000, nullable: true }) ?? null,
        status,
        str(body, "next_step", { max: 500, nullable: true }) ?? null,
        timestamp(body, "due_at") ?? null,
        timestamp(body, "remind_at") ?? null,
        str(body, "calendar_event_id", { max: 200, nullable: true }) ?? null,
        num(body, "sort") ?? 0,
        sourceFor(s, body, "created_via"),
        stamp,
        stamp,
      )
      .first<Row>();
    return json({ task: row }, 201);
  } catch (err) {
    if (err instanceof HttpError) throw err;
    mapDbError(err);
  }
}

/** PATCH edits content fields. Status changes go through the action endpoints. */
export async function updateTask(req: Request, env: Env, s: Session, id: string): Promise<Response> {
  const body = await readJson(req);
  const sets: string[] = [];
  const binds: unknown[] = [];
  const fields: [string, unknown][] = [
    ["title", str(body, "title", { min: 1, max: 500 })],
    ["details", str(body, "details", { max: 10000, nullable: true })],
    ["next_step", str(body, "next_step", { max: 500, nullable: true })],
    ["park_note", str(body, "park_note", { max: 1000, nullable: true })],
    ["area_id", uuidField(body, "area_id")],
    ["parent_id", uuidField(body, "parent_id")],
    ["due_at", timestamp(body, "due_at")],
    ["remind_at", timestamp(body, "remind_at")],
    ["calendar_event_id", str(body, "calendar_event_id", { max: 200, nullable: true })],
    ["sort", num(body, "sort")],
  ];
  for (const [col, val] of fields) {
    if (val !== undefined) sets.push(`${col} = ?`), binds.push(val);
  }
  if ("status" in body) throw new HttpError(400, "use_action", "Change status with start, park, complete or reopen");
  if (sets.length === 0) throw new HttpError(400, "nothing_to_update");
  sets.push("updated_at = ?");
  binds.push(now());
  try {
    const row = await env.DB.prepare(
      `UPDATE tasks SET ${sets.join(", ")} WHERE id = ? AND user_id = ? AND deleted_at IS NULL
       RETURNING ${TASK_COLUMNS}`,
    )
      .bind(...binds, id, s.userId)
      .first<Row>();
    if (!row) throw new HttpError(404, "task_not_found");
    return json({ task: row });
  } catch (err) {
    if (err instanceof HttpError) throw err;
    mapDbError(err);
  }
}

/** Soft delete, including subtasks, so other devices see the deletion on sync. */
export async function deleteTask(env: Env, s: Session, id: string): Promise<Response> {
  const stamp = now();
  const [, res] = await env.DB.batch([
    env.DB.prepare(
      "UPDATE tasks SET deleted_at = ?, updated_at = ? WHERE parent_id = ? AND user_id = ? AND deleted_at IS NULL",
    ).bind(stamp, stamp, id, s.userId),
    env.DB.prepare(
      "UPDATE tasks SET deleted_at = ?, updated_at = ? WHERE id = ? AND user_id = ? AND deleted_at IS NULL",
    ).bind(stamp, stamp, id, s.userId),
  ]);
  if (!res.meta.changes) throw new HttpError(404, "task_not_found");
  return new Response(null, { status: 204 });
}

// ================================================================= state changes

/** SQL for the seconds a task has been active, as of `?` (bound timestamp). */
const DURATION_SQL =
  "CASE WHEN status = 'active' AND started_at IS NOT NULL THEN CAST(max(0, (julianday(?) - julianday(started_at)) * 86400) AS INTEGER) END";

/**
 * POST /v1/tasks/:id/start { previous_note?, previous_reason?, source? }
 * Makes a top-level task active. Any other active task is parked first, in one transaction.
 */
export async function startTask(req: Request, env: Env, s: Session, id: string): Promise<Response> {
  const body = await readJson(req).catch(() => ({}) as Row);
  const prevNote = str(body, "previous_note", { max: 1000, nullable: true }) ?? null;
  const prevReason: ParkReason = oneOf(body, "previous_reason", PARK_REASONS) ?? "later";
  const source = sourceFor(s, body);

  const target = await getTask(env, s.userId, id);
  if (target.parent_id) throw new HttpError(409, "subtask_cannot_start", "Start the parent task");
  if (target.status === "active") return json({ task: target, parked: null });
  if (target.status !== "inbox" && target.status !== "parked") {
    throw new HttpError(409, "invalid_state", `Cannot start a ${target.status} task; reopen it first`);
  }

  const stamp = now();
  const startable =
    "id = ? AND user_id = ? AND status IN ('inbox', 'parked') AND parent_id IS NULL AND deleted_at IS NULL";
  // The other active task, guarded so nothing is parked unless the target can really start.
  const otherActive = `user_id = ? AND status = 'active' AND parent_id IS NULL AND deleted_at IS NULL AND id != ?
    AND EXISTS (SELECT 1 FROM tasks t WHERE t.id = ? AND t.user_id = ? AND t.status IN ('inbox', 'parked')
                AND t.parent_id IS NULL AND t.deleted_at IS NULL)`;

  const previous = await env.DB.prepare(
    "SELECT id FROM tasks WHERE user_id = ? AND status = 'active' AND parent_id IS NULL AND deleted_at IS NULL",
  )
    .bind(s.userId)
    .first<{ id: string }>();

  const results = await env.DB.batch([
    // 1. history row for the task being parked (needs started_at before the update)
    env.DB.prepare(
      `INSERT INTO task_events (id, user_id, task_id, kind, note, reason, duration_seconds, source, occurred_at)
       SELECT ?, user_id, id, 'parked', ?, ?, ${DURATION_SQL}, ?, ? FROM tasks WHERE ${otherActive}`,
    ).bind(newId(), prevNote, prevReason, stamp, source, stamp, s.userId, id, id, s.userId),
    // 2. park it
    env.DB.prepare(
      `UPDATE tasks SET status = 'parked', park_note = COALESCE(?, park_note), park_reason = ?,
         parked_at = ?, updated_at = ? WHERE ${otherActive}`,
    ).bind(prevNote, prevReason, stamp, stamp, s.userId, id, id, s.userId),
    // 3. history row for the started task
    env.DB.prepare(
      `INSERT INTO task_events (id, user_id, task_id, kind, source, occurred_at)
       SELECT ?, user_id, id, CASE status WHEN 'parked' THEN 'resumed' ELSE 'started' END, ?, ?
       FROM tasks WHERE ${startable}`,
    ).bind(newId(), source, stamp, id, s.userId),
    // 4. start it
    env.DB.prepare(
      `UPDATE tasks SET status = 'active', started_at = ?, updated_at = ? WHERE ${startable}
       RETURNING ${TASK_COLUMNS}`,
    ).bind(stamp, stamp, id, s.userId),
  ]);

  const task = results[3].results[0] as Row | undefined;
  if (!task) throw new HttpError(409, "invalid_state", "Task changed concurrently; retry");
  const parkedId = results[1].meta.changes ? previous?.id ?? null : null;
  const parked = parkedId ? await getTask(env, s.userId, parkedId) : null;
  return json({ task, parked });
}

/**
 * POST /v1/tasks/:id/park  or  POST /v1/park (the current active task)
 * { note?, reason?, remind_at?, source? }
 */
export async function parkTask(req: Request, env: Env, s: Session, id: string | null): Promise<Response> {
  const body = await readJson(req).catch(() => ({}) as Row);
  const note = str(body, "note", { max: 1000, nullable: true }) ?? null;
  const reason: ParkReason = oneOf(body, "reason", PARK_REASONS) ?? "later";
  const remindAt = timestamp(body, "remind_at") ?? null;
  const source = sourceFor(s, body);
  const stamp = now();

  const target = id
    ? await getTask(env, s.userId, id)
    : await env.DB.prepare(
        `SELECT ${TASK_COLUMNS} FROM tasks WHERE user_id = ? AND status = 'active' AND parent_id IS NULL AND deleted_at IS NULL`,
      )
        .bind(s.userId)
        .first<Row>();
  if (!target) throw new HttpError(404, id ? "task_not_found" : "no_active_task");
  if (!["active", "inbox", "parked"].includes(target.status as string)) {
    throw new HttpError(409, "invalid_state", `Cannot park a ${target.status} task`);
  }

  const cond = "id = ? AND user_id = ? AND status IN ('active', 'inbox', 'parked') AND deleted_at IS NULL";
  const results = await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO task_events (id, user_id, task_id, kind, note, reason, duration_seconds, source, occurred_at)
       SELECT ?, user_id, id, 'parked', ?, ?, ${DURATION_SQL}, ?, ? FROM tasks WHERE ${cond}`,
    ).bind(newId(), note, reason, stamp, source, stamp, target.id, s.userId),
    env.DB.prepare(
      `UPDATE tasks SET status = 'parked', park_note = COALESCE(?, park_note), park_reason = ?,
         parked_at = ?, remind_at = COALESCE(?, remind_at), updated_at = ?
       WHERE ${cond} RETURNING ${TASK_COLUMNS}`,
    ).bind(note, reason, stamp, remindAt, stamp, target.id, s.userId),
  ]);
  const task = results[1].results[0];
  if (!task) throw new HttpError(409, "invalid_state", "Task changed concurrently; retry");
  return json({ task });
}

/** POST /v1/tasks/:id/complete { source? } — works for subtasks too. */
export async function completeTask(req: Request, env: Env, s: Session, id: string): Promise<Response> {
  const body = await readJson(req).catch(() => ({}) as Row);
  const source = sourceFor(s, body);
  const stamp = now();
  const cond = "id = ? AND user_id = ? AND status IN ('active', 'inbox', 'parked') AND deleted_at IS NULL";
  const results = await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO task_events (id, user_id, task_id, kind, duration_seconds, source, occurred_at)
       SELECT ?, user_id, id, 'done', ${DURATION_SQL}, ?, ? FROM tasks WHERE ${cond}`,
    ).bind(newId(), stamp, source, stamp, id, s.userId),
    env.DB.prepare(
      `UPDATE tasks SET status = 'done', completed_at = ?, remind_at = NULL, updated_at = ?
       WHERE ${cond} RETURNING ${TASK_COLUMNS}`,
    ).bind(stamp, stamp, id, s.userId),
  ]);
  const task = results[1].results[0];
  if (!task) {
    await getTask(env, s.userId, id); // 404 if missing
    throw new HttpError(409, "invalid_state", "Task is already done or archived");
  }
  return json({ task });
}

/** POST /v1/tasks/:id/reopen { source? } — done/archived back to inbox. */
export async function reopenTask(req: Request, env: Env, s: Session, id: string): Promise<Response> {
  const body = await readJson(req).catch(() => ({}) as Row);
  const source = sourceFor(s, body);
  const stamp = now();
  const cond = "id = ? AND user_id = ? AND status IN ('done', 'archived') AND deleted_at IS NULL";
  const results = await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO task_events (id, user_id, task_id, kind, source, occurred_at)
       SELECT ?, user_id, id, 'reopened', ?, ? FROM tasks WHERE ${cond}`,
    ).bind(newId(), source, stamp, id, s.userId),
    env.DB.prepare(
      `UPDATE tasks SET status = 'inbox', completed_at = NULL, updated_at = ? WHERE ${cond}
       RETURNING ${TASK_COLUMNS}`,
    ).bind(stamp, id, s.userId),
  ]);
  const task = results[1].results[0];
  if (!task) {
    await getTask(env, s.userId, id);
    throw new HttpError(409, "invalid_state", "Only done or archived tasks can be reopened");
  }
  return json({ task });
}

/** POST /v1/tasks/:id/archive { source? } */
export async function archiveTask(env: Env, s: Session, id: string): Promise<Response> {
  const stamp = now();
  const row = await env.DB.prepare(
    `UPDATE tasks SET status = 'archived', remind_at = NULL, updated_at = ?
     WHERE id = ? AND user_id = ? AND status != 'active' AND deleted_at IS NULL
     RETURNING ${TASK_COLUMNS}`,
  )
    .bind(stamp, id, s.userId)
    .first<Row>();
  if (!row) {
    await getTask(env, s.userId, id);
    throw new HttpError(409, "invalid_state", "Park or complete the active task first");
  }
  return json({ task: row });
}

/** POST /v1/tasks/:id/notes { note, source? } — free-form note in the history. */
export async function addNote(req: Request, env: Env, s: Session, id: string): Promise<Response> {
  const body = await readJson(req);
  const note = str(body, "note", { min: 1, max: 1000 });
  if (!note) throw new HttpError(400, "invalid_field", "note is required");
  await getTask(env, s.userId, id);
  const row = await env.DB.prepare(
    `INSERT INTO task_events (id, user_id, task_id, kind, note, source, occurred_at)
     VALUES (?, ?, ?, 'note', ?, ?, ?) RETURNING ${EVENT_COLUMNS}`,
  )
    .bind(newId(), s.userId, id, note, sourceFor(s, body), now())
    .first<Row>();
  return json({ event: row }, 201);
}

/** GET /v1/tasks/:id/events — the "İz" history, newest first. */
export async function listEvents(env: Env, s: Session, id: string): Promise<Response> {
  await getTask(env, s.userId, id);
  const { results } = await env.DB.prepare(
    `SELECT ${EVENT_COLUMNS} FROM task_events WHERE task_id = ? AND user_id = ? ORDER BY occurred_at DESC LIMIT 500`,
  )
    .bind(id, s.userId)
    .all();
  return json({ events: results });
}

// ================================================================= sync

const SYNC_LIMIT = 1000;
/** Re-send a few seconds of overlap so writes that raced the previous sync are not missed. */
const SYNC_OVERLAP_MS = 5_000;

/**
 * GET /v1/sync?since=<server_time from the previous response>
 * Returns everything changed since then, including soft-deleted rows. Upsert by id.
 */
export async function sync(url: URL, env: Env, s: Session): Promise<Response> {
  const serverTime = now();
  const sinceRaw = url.searchParams.get("since");
  let since = "1970-01-01T00:00:00.000Z";
  if (sinceRaw) {
    const t = Date.parse(sinceRaw);
    if (Number.isNaN(t)) throw new HttpError(400, "invalid_field", "since");
    since = new Date(t - SYNC_OVERLAP_MS).toISOString();
  }
  const [areas, tasks, events] = await env.DB.batch([
    env.DB.prepare(`SELECT ${AREA_COLUMNS} FROM areas WHERE user_id = ? AND updated_at >= ? ORDER BY updated_at LIMIT ?`)
      .bind(s.userId, since, SYNC_LIMIT),
    env.DB.prepare(`SELECT ${TASK_COLUMNS} FROM tasks WHERE user_id = ? AND updated_at >= ? ORDER BY updated_at LIMIT ?`)
      .bind(s.userId, since, SYNC_LIMIT),
    env.DB.prepare(`SELECT ${EVENT_COLUMNS} FROM task_events WHERE user_id = ? AND occurred_at >= ? ORDER BY occurred_at LIMIT ?`)
      .bind(s.userId, since, SYNC_LIMIT),
  ]);
  const hasMore = [areas, tasks, events].some((r) => r.results.length >= SYNC_LIMIT);
  // When truncated, the client should call again with the oldest "last" timestamp it received.
  let next = serverTime;
  if (hasMore) {
    const lasts = [
      (areas.results.at(-1) as Row | undefined)?.updated_at,
      (tasks.results.at(-1) as Row | undefined)?.updated_at,
      (events.results.at(-1) as Row | undefined)?.occurred_at,
    ].filter((v): v is string => typeof v === "string");
    next = lasts.sort()[0] ?? serverTime;
  }
  return json({
    server_time: next,
    has_more: hasMore,
    areas: areas.results,
    tasks: tasks.results,
    events: events.results,
  });
}

// ================================================================= device tokens

/** PUT /v1/device-tokens { apns_token, environment } */
export async function putDeviceToken(req: Request, env: Env, s: Session): Promise<Response> {
  const body = await readJson(req);
  const token = str(body, "apns_token", { min: 1, max: 200 });
  if (!token || !/^[0-9a-fA-F]+$/.test(token)) throw new HttpError(400, "invalid_field", "apns_token");
  const environment = oneOf(body, "environment", ["sandbox", "production"] as const);
  if (!environment) throw new HttpError(400, "invalid_field", "environment");
  await env.DB.prepare(
    `INSERT INTO device_tokens (user_id, apns_token, environment, updated_at) VALUES (?, ?, ?, ?)
     ON CONFLICT (user_id, apns_token) DO UPDATE SET environment = excluded.environment, updated_at = excluded.updated_at`,
  )
    .bind(s.userId, token.toLowerCase(), environment, now())
    .run();
  return new Response(null, { status: 204 });
}

/** DELETE /v1/device-tokens/:token */
export async function deleteDeviceToken(env: Env, s: Session, token: string): Promise<Response> {
  await env.DB.prepare("DELETE FROM device_tokens WHERE user_id = ? AND apns_token = ?")
    .bind(s.userId, token.toLowerCase())
    .run();
  return new Response(null, { status: 204 });
}
