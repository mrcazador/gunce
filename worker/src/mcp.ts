// Remote MCP endpoint for Claude (Streamable HTTP, stateless JSON responses).
//
// Tools call the same handlers as the REST API with the caller's 'mcp' session, so validation,
// the one-active-task rule and `user_id` scoping are shared. Sessions of kind 'mcp' always write
// `claude` as the source and as `created_via`.

import { authenticate, type Session } from "./auth";
import { type Env, HttpError, isUuid, json } from "./http";
import * as t from "./tasks";

const PROTOCOL_VERSIONS = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];

const INSTRUCTIONS = `PickUp is the user's task app for interrupted work. Core idea: never lose the place you left off.
- Exactly one task is active at a time. Starting another parks the current one; ask the user where they left off and pass it as previous_note.
- Parking stores a one-line "where I left off" note and a reason: waiting (waiting for a reply), need_info (need information), later (continue later).
- Areas: İş (work), Hayat (life), Spor (sport), Yatırım (investing), plus any the user added.
- New tasks land in the inbox. Steps are ordered subtasks; the first open step is the next step.
- The user writes in Turkish; keep titles and notes in the user's language.
- Dates are ISO 8601 with a UTC offset (e.g. 2026-10-14T09:00:00+03:00).
Call get_overview first to see what the user is working on.`;

type Args = Record<string, unknown>;
type Row = Record<string, unknown>;

interface Tool {
  name: string;
  title: string;
  description: string;
  inputSchema: Record<string, unknown>;
  annotations: Record<string, boolean | string>;
  run: (env: Env, s: Session, args: Args) => Promise<unknown>;
}

// ---------------------------------------------------------------- helpers

/** Calls a REST handler in-process with a JSON body and returns its JSON. */
async function call(handler: (req: Request) => Promise<Response>, body: Args = {}): Promise<any> {
  const req = new Request("https://mcp.internal/", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  const res = await handler(req);
  return res.status === 204 ? null : res.json();
}

const listUrl = (params: Record<string, string>) =>
  new URL(`https://mcp.internal/?${new URLSearchParams(params)}`);

function taskId(args: Args, key = "id"): string {
  const v = args[key];
  if (!isUuid(v)) throw new HttpError(400, "invalid_field", `${key} must be a task id from get_overview or search_tasks`);
  return v.toLowerCase();
}

async function areaMap(env: Env, s: Session): Promise<Map<string, string>> {
  const { areas } = await (await t.listAreas(env, s)).json<{ areas: Row[] }>();
  return new Map(areas.map((a) => [a.id as string, a.name as string]));
}

/** Area name (case-insensitive) → id. */
async function areaId(env: Env, s: Session, name: unknown): Promise<string | null | undefined> {
  if (name === undefined) return undefined;
  if (name === null || name === "") return null;
  if (typeof name !== "string") throw new HttpError(400, "invalid_field", "area must be an area name");
  const areas = await areaMap(env, s);
  const wanted = name.trim().toLocaleLowerCase("tr");
  for (const [id, n] of areas) if (n.toLocaleLowerCase("tr") === wanted) return id;
  throw new HttpError(400, "unknown_area", `No area named "${name}". Areas: ${[...areas.values()].join(", ")}`);
}

/** A compact task for Claude: names instead of ids where it helps, no empty fields. */
function brief(task: Row, areas: Map<string, string>, steps?: Row[]): Row {
  const out: Row = {
    id: task.id,
    title: task.title,
    status: task.status,
    area: task.area_id ? areas.get(task.area_id as string) ?? null : null,
    details: task.details,
    next_step: task.next_step,
    park_note: task.park_note,
    park_reason: task.park_reason,
    parked_at: task.status === "parked" ? task.parked_at : null,
    started_at: task.status === "active" ? task.started_at : null,
    due_at: task.due_at,
    remind_at: task.remind_at,
    completed_at: task.completed_at,
    created_via: task.created_via === "claude" ? "claude" : null,
  };
  if (steps && steps.length > 0) {
    out.steps = steps.map((st) => ({ id: st.id, title: st.title, done: st.status === "done" }));
  }
  for (const k of Object.keys(out)) if (out[k] === null || out[k] === undefined) delete out[k];
  return out;
}

async function withSteps(env: Env, s: Session, id: string, areas: Map<string, string>): Promise<Row> {
  const { task, subtasks } = await (await t.readTask(env, s, id)).json<{ task: Row; subtasks: Row[] }>();
  return brief(task, areas, subtasks);
}

const isoDate = { type: ["string", "null"], description: "ISO 8601 with UTC offset, or null to clear" };
const reasonSchema = {
  type: "string",
  enum: ["waiting", "need_info", "later"],
  description: "waiting = waiting for a reply, need_info = need information, later = continue later",
};

// ---------------------------------------------------------------- tools

const tools: Tool[] = [
  {
    name: "get_overview",
    title: "Overview",
    description:
      "What the user is working on now: the active task (with steps), parked tasks with their 'where I left off' notes, the inbox, and the areas.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    annotations: { readOnlyHint: true },
    async run(env, s) {
      const areas = await areaMap(env, s);
      const { tasks } = await (
        await t.listTasks(listUrl({ status: "active,parked,inbox", parent_id: "none", limit: "200" }), env, s)
      ).json<{ tasks: Row[] }>();
      const active = tasks.find((x) => x.status === "active");
      return {
        active: active ? await withSteps(env, s, active.id as string, areas) : null,
        parked: tasks.filter((x) => x.status === "parked").map((x) => brief(x, areas)),
        inbox: tasks.filter((x) => x.status === "inbox").map((x) => brief(x, areas)),
        areas: [...areas.values()],
      };
    },
  },
  {
    name: "search_tasks",
    title: "Search tasks",
    description: "Find top-level tasks by text (title, details, park note), status and area.",
    inputSchema: {
      type: "object",
      properties: {
        query: { type: "string", maxLength: 200 },
        status: {
          type: "array",
          items: { type: "string", enum: ["inbox", "active", "parked", "done", "archived"] },
          description: "Defaults to open tasks (inbox, active, parked)",
        },
        area: { type: "string", description: "Area name" },
        limit: { type: "integer", minimum: 1, maximum: 100, default: 30 },
      },
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true },
    async run(env, s, args) {
      const areas = await areaMap(env, s);
      const params: Record<string, string> = { parent_id: "none" };
      params.status = Array.isArray(args.status) && args.status.length ? args.status.join(",") : "inbox,active,parked";
      if (typeof args.query === "string" && args.query.trim()) params.q = args.query.trim();
      const area = await areaId(env, s, args.area);
      if (area) params.area_id = area;
      params.limit = String(Math.min(Math.max(Number(args.limit) || 30, 1), 100));
      const { tasks } = await (await t.listTasks(listUrl(params), env, s)).json<{ tasks: Row[] }>();
      return { tasks: tasks.map((x) => brief(x, areas)) };
    },
  },
  {
    name: "get_task",
    title: "Get task",
    description: "One task with its steps and recent history (started, parked with notes, resumed, done, notes).",
    inputSchema: { type: "object", properties: { id: { type: "string" } }, required: ["id"], additionalProperties: false },
    annotations: { readOnlyHint: true },
    async run(env, s, args) {
      const id = taskId(args);
      const areas = await areaMap(env, s);
      const task = await withSteps(env, s, id, areas);
      const { events } = await (await t.listEvents(env, s, id)).json<{ events: Row[] }>();
      task.history = events.slice(0, 30).map((e) => {
        const out: Row = { kind: e.kind, at: e.occurred_at, note: e.note, reason: e.reason, source: e.source };
        for (const k of Object.keys(out)) if (out[k] === null) delete out[k];
        return out;
      });
      return task;
    },
  },
  {
    name: "create_task",
    title: "Create task",
    description:
      "Add a task to the inbox. Optionally with an area, a due date, a reminder and ordered steps. Use parent_id to add a single step to an existing task.",
    inputSchema: {
      type: "object",
      properties: {
        title: { type: "string", minLength: 1, maxLength: 500 },
        details: { type: "string", maxLength: 10000 },
        area: { type: "string", description: "Area name, e.g. İş" },
        due_at: isoDate,
        remind_at: isoDate,
        steps: { type: "array", items: { type: "string", maxLength: 500 }, maxItems: 20, description: "Ordered steps" },
        parent_id: { type: "string", description: "Make this a step of that task" },
      },
      required: ["title"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false },
    async run(env, s, args) {
      const body: Args = { title: args.title };
      if (args.details !== undefined) body.details = args.details;
      if (args.due_at) body.due_at = args.due_at;
      if (args.remind_at) body.remind_at = args.remind_at;
      const area = await areaId(env, s, args.area);
      if (area) body.area_id = area;
      if (args.parent_id !== undefined) {
        const parentId = taskId(args, "parent_id");
        const { subtasks } = await (await t.readTask(env, s, parentId)).json<{ subtasks: Row[] }>();
        body.parent_id = parentId;
        body.sort = subtasks.length;
      }
      const { task } = await call((req) => t.createTask(req, env, s), body);
      const steps = Array.isArray(args.steps) ? args.steps.slice(0, 20) : [];
      for (const [i, title] of steps.entries()) {
        await call((req) => t.createTask(req, env, s), { title, parent_id: task.id, sort: i });
      }
      return withSteps(env, s, task.id as string, await areaMap(env, s));
    },
  },
  {
    name: "update_task",
    title: "Update task",
    description: "Edit a task's title, details, next step, area, due date or reminder. Pass null to clear a date.",
    inputSchema: {
      type: "object",
      properties: {
        id: { type: "string" },
        title: { type: "string", minLength: 1, maxLength: 500 },
        details: { type: ["string", "null"], maxLength: 10000 },
        next_step: { type: ["string", "null"], maxLength: 500 },
        area: { type: ["string", "null"], description: "Area name, or null for none" },
        due_at: isoDate,
        remind_at: isoDate,
      },
      required: ["id"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true },
    async run(env, s, args) {
      const id = taskId(args);
      const body: Args = {};
      for (const k of ["title", "details", "next_step", "due_at", "remind_at"]) if (k in args) body[k] = args[k];
      const area = await areaId(env, s, args.area);
      if (area !== undefined) body.area_id = area;
      await call((req) => t.updateTask(req, env, s, id), body);
      return withSteps(env, s, id, await areaMap(env, s));
    },
  },
  {
    name: "start_task",
    title: "Start task",
    description:
      "Make a task the active one (or resume a parked one). If another task is active it is parked first: ask the user where they left off and pass previous_note.",
    inputSchema: {
      type: "object",
      properties: {
        id: { type: "string" },
        previous_note: { type: "string", maxLength: 1000, description: "Where the user left off on the task being parked" },
        previous_reason: reasonSchema,
      },
      required: ["id"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true },
    async run(env, s, args) {
      const id = taskId(args);
      const body: Args = {};
      if (args.previous_note) body.previous_note = args.previous_note;
      if (args.previous_reason) body.previous_reason = args.previous_reason;
      const { parked } = await call((req) => t.startTask(req, env, s, id), body);
      const areas = await areaMap(env, s);
      return { active: await withSteps(env, s, id, areas), parked: parked ? brief(parked, areas) : null };
    },
  },
  {
    name: "park_task",
    title: "Park task",
    description:
      "Park a task with a one-line note of where the user left off. Without id, parks the active task. Optionally set a reminder to come back.",
    inputSchema: {
      type: "object",
      properties: {
        id: { type: "string", description: "Defaults to the active task" },
        note: { type: "string", maxLength: 1000, description: "Where the user left off" },
        reason: reasonSchema,
        remind_at: { type: "string", description: "ISO 8601 with UTC offset" },
      },
      additionalProperties: false,
    },
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false },
    async run(env, s, args) {
      const id = args.id === undefined ? null : taskId(args);
      const body: Args = {};
      if (args.note) body.note = args.note;
      if (args.reason) body.reason = args.reason;
      if (args.remind_at) body.remind_at = args.remind_at;
      const { task } = await call((req) => t.parkTask(req, env, s, id), body);
      return brief(task, await areaMap(env, s));
    },
  },
  {
    name: "complete_task",
    title: "Complete task",
    description: "Mark a task or a step as done.",
    inputSchema: { type: "object", properties: { id: { type: "string" } }, required: ["id"], additionalProperties: false },
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false },
    async run(env, s, args) {
      const id = taskId(args);
      const { task } = await call((req) => t.completeTask(req, env, s, id));
      return brief(task, await areaMap(env, s));
    },
  },
  {
    name: "add_note",
    title: "Add note",
    description: "Add a free-form note to a task's history.",
    inputSchema: {
      type: "object",
      properties: { id: { type: "string" }, note: { type: "string", minLength: 1, maxLength: 1000 } },
      required: ["id", "note"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false },
    async run(env, s, args) {
      const id = taskId(args);
      await call((req) => t.addNote(req, env, s, id), { note: args.note });
      return { ok: true };
    },
  },
];

const toolByName = new Map(tools.map((x) => [x.name, x]));

// ---------------------------------------------------------------- JSON-RPC

interface RpcMessage {
  jsonrpc?: string;
  id?: string | number | null;
  method?: string;
  params?: Record<string, unknown>;
}

const rpcResult = (id: RpcMessage["id"], result: unknown) => ({ jsonrpc: "2.0", id, result });
const rpcError = (id: RpcMessage["id"], code: number, message: string) => ({ jsonrpc: "2.0", id: id ?? null, error: { code, message } });

async function handle(msg: RpcMessage, env: Env, s: Session): Promise<object | null> {
  if (msg.jsonrpc !== "2.0" || typeof msg.method !== "string") return rpcError(msg.id, -32600, "Invalid request");
  if (msg.id === undefined) return null; // notifications (initialized, cancelled) need no reply

  switch (msg.method) {
    case "initialize": {
      const asked = msg.params?.protocolVersion;
      const version = typeof asked === "string" && PROTOCOL_VERSIONS.includes(asked) ? asked : PROTOCOL_VERSIONS[1];
      return rpcResult(msg.id, {
        protocolVersion: version,
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: "pickup", title: "PickUp", version: "0.1.0" },
        instructions: INSTRUCTIONS,
      });
    }
    case "ping":
      return rpcResult(msg.id, {});
    case "tools/list":
      return rpcResult(msg.id, {
        tools: tools.map(({ name, title, description, inputSchema, annotations }) => ({
          name,
          title,
          description,
          inputSchema,
          annotations: { title, openWorldHint: false, ...annotations },
        })),
      });
    case "tools/call": {
      const tool = toolByName.get(String(msg.params?.name));
      if (!tool) return rpcError(msg.id, -32602, `Unknown tool: ${String(msg.params?.name)}`);
      const args = (msg.params?.arguments ?? {}) as Args;
      if (typeof args !== "object" || Array.isArray(args)) return rpcError(msg.id, -32602, "arguments must be an object");
      try {
        const out = await tool.run(env, s, args);
        return rpcResult(msg.id, {
          content: [{ type: "text", text: JSON.stringify(out) }],
          structuredContent: out,
          isError: false,
        });
      } catch (err) {
        if (!(err instanceof HttpError)) throw err;
        return rpcResult(msg.id, {
          content: [{ type: "text", text: `${err.code}: ${err.message}` }],
          isError: true,
        });
      }
    }
    default:
      return rpcError(msg.id, -32601, `Method not found: ${msg.method}`);
  }
}

/** POST /mcp */
export async function mcp(req: Request, env: Env, url: URL): Promise<Response> {
  let session: Session;
  try {
    session = await authenticate(req, env);
  } catch (err) {
    if (!(err instanceof HttpError) || err.status !== 401) throw err;
    return new Response(JSON.stringify({ error: "unauthorized" }), {
      status: 401,
      headers: {
        "content-type": "application/json",
        "www-authenticate": `Bearer resource_metadata="${url.origin}/.well-known/oauth-protected-resource"`,
      },
    });
  }
  if (session.kind !== "mcp") throw new HttpError(403, "forbidden", "Use a token from the Claude connector");

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return json(rpcError(null, -32700, "Parse error"), 400);
  }
  const batch = Array.isArray(body);
  const messages = (batch ? body : [body]) as RpcMessage[];
  if (messages.length === 0 || messages.length > 20) return json(rpcError(null, -32600, "Invalid request"), 400);

  const replies = [];
  for (const m of messages) {
    const reply = await handle(m && typeof m === "object" ? m : {}, env, session);
    if (reply) replies.push(reply);
  }
  if (replies.length === 0) return new Response(null, { status: 202 });
  return json(batch ? replies : replies[0]);
}
