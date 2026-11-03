-- Voice notes: one row per request to /v1/voice, only to cap how many a user can send a day.
-- Nothing of what was said is stored here; the transcript is not kept by the Worker.
CREATE TABLE voice_requests (
  id          TEXT PRIMARY KEY,
  user_id     TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE INDEX voice_requests_user_idx ON voice_requests (user_id, created_at);
