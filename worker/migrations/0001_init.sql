-- Günce: initial D1 (SQLite) schema.
-- D1 has no row level security. Isolation is enforced in the Worker: every query is scoped
-- with `user_id = ?` bound to the authenticated session. Triggers below are a second line of
-- defence for cross-user references.
-- Timestamps are ISO 8601 UTC strings with milliseconds, e.g. 2026-10-12T09:30:00.000Z.

-- ---------------------------------------------------------------- users and sessions
CREATE TABLE users (
  id          TEXT PRIMARY KEY,                -- UUID
  apple_sub   TEXT NOT NULL UNIQUE,            -- Sign in with Apple stable user id
  created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

-- Only the SHA-256 hash of a session token is stored.
CREATE TABLE sessions (
  token_hash   TEXT PRIMARY KEY,
  user_id      TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  kind         TEXT NOT NULL DEFAULT 'app' CHECK (kind IN ('app', 'mcp')),
  label        TEXT CHECK (length(label) <= 100),
  created_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  last_used_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  expires_at   TEXT NOT NULL
);
CREATE INDEX sessions_user_idx ON sessions (user_id);

-- ---------------------------------------------------------------- areas
CREATE TABLE areas (
  id          TEXT PRIMARY KEY,
  user_id     TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  name        TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 40),
  symbol      TEXT NOT NULL DEFAULT 'circle' CHECK (length(symbol) <= 80),
  color       TEXT NOT NULL DEFAULT 'gray' CHECK (length(color) <= 30),
  sort        INTEGER NOT NULL DEFAULT 0,
  created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  updated_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  deleted_at  TEXT,
  UNIQUE (user_id, name)
);
CREATE INDEX areas_user_updated_idx ON areas (user_id, updated_at);

-- ---------------------------------------------------------------- tasks
CREATE TABLE tasks (
  id                 TEXT PRIMARY KEY,
  user_id            TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  area_id            TEXT REFERENCES areas (id) ON DELETE SET NULL,
  parent_id          TEXT REFERENCES tasks (id) ON DELETE CASCADE,
  title              TEXT NOT NULL CHECK (length(title) BETWEEN 1 AND 500),
  details            TEXT CHECK (length(details) <= 10000),
  status             TEXT NOT NULL DEFAULT 'inbox'
                       CHECK (status IN ('inbox', 'active', 'parked', 'done', 'archived')),
  next_step          TEXT CHECK (length(next_step) <= 500),
  park_note          TEXT CHECK (length(park_note) <= 1000),
  park_reason        TEXT CHECK (park_reason IN ('waiting', 'need_info', 'later')),
  parked_at          TEXT,
  started_at         TEXT,
  due_at             TEXT,
  remind_at          TEXT,
  calendar_event_id  TEXT CHECK (length(calendar_event_id) <= 200),
  sort               REAL NOT NULL DEFAULT 0,
  created_via        TEXT NOT NULL DEFAULT 'app'
                       CHECK (created_via IN ('app', 'claude', 'widget', 'siri', 'share')),
  created_at         TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  updated_at         TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  completed_at       TEXT,
  deleted_at         TEXT
);

CREATE INDEX tasks_user_status_idx ON tasks (user_id, status) WHERE deleted_at IS NULL;
CREATE INDEX tasks_user_remind_idx ON tasks (user_id, remind_at)
  WHERE remind_at IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX tasks_parent_idx ON tasks (parent_id);
CREATE INDEX tasks_user_updated_idx ON tasks (user_id, updated_at);

-- The core rule: at most one active top-level task per user.
CREATE UNIQUE INDEX tasks_one_active_per_user ON tasks (user_id)
  WHERE status = 'active' AND parent_id IS NULL AND deleted_at IS NULL;

-- A task's area and parent must belong to the same user.
CREATE TRIGGER tasks_ownership_insert BEFORE INSERT ON tasks
BEGIN
  SELECT RAISE(ABORT, 'area does not belong to user')
   WHERE NEW.area_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM areas a WHERE a.id = NEW.area_id AND a.user_id = NEW.user_id);
  SELECT RAISE(ABORT, 'parent task does not belong to user')
   WHERE NEW.parent_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM tasks t WHERE t.id = NEW.parent_id AND t.user_id = NEW.user_id);
END;

CREATE TRIGGER tasks_ownership_update BEFORE UPDATE OF area_id, parent_id, user_id ON tasks
BEGIN
  SELECT RAISE(ABORT, 'area does not belong to user')
   WHERE NEW.area_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM areas a WHERE a.id = NEW.area_id AND a.user_id = NEW.user_id);
  SELECT RAISE(ABORT, 'parent task does not belong to user')
   WHERE NEW.parent_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM tasks t WHERE t.id = NEW.parent_id AND t.user_id = NEW.user_id);
  SELECT RAISE(ABORT, 'task cannot be its own parent') WHERE NEW.parent_id = NEW.id;
END;

-- ---------------------------------------------------------------- history ("İz")
CREATE TABLE task_events (
  id                TEXT PRIMARY KEY,
  user_id           TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  task_id           TEXT NOT NULL REFERENCES tasks (id) ON DELETE CASCADE,
  kind              TEXT NOT NULL
                      CHECK (kind IN ('created', 'started', 'parked', 'resumed', 'done', 'reopened', 'note')),
  note              TEXT CHECK (length(note) <= 1000),
  reason            TEXT CHECK (reason IN ('waiting', 'need_info', 'later')),
  duration_seconds  INTEGER CHECK (duration_seconds >= 0),
  source            TEXT NOT NULL DEFAULT 'app'
                      CHECK (source IN ('app', 'claude', 'widget', 'siri', 'share')),
  occurred_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE INDEX task_events_task_idx ON task_events (task_id, occurred_at DESC);
CREATE INDEX task_events_user_idx ON task_events (user_id, occurred_at);

-- Log creation automatically.
CREATE TRIGGER tasks_log_created AFTER INSERT ON tasks
BEGIN
  INSERT INTO task_events (id, user_id, task_id, kind, source)
  VALUES (lower(hex(randomblob(16))), NEW.user_id, NEW.id, 'created', NEW.created_via);
END;

-- ---------------------------------------------------------------- push tokens
CREATE TABLE device_tokens (
  user_id     TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  apns_token  TEXT NOT NULL CHECK (length(apns_token) <= 200),
  environment TEXT NOT NULL CHECK (environment IN ('sandbox', 'production')),
  updated_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  PRIMARY KEY (user_id, apns_token)
);
