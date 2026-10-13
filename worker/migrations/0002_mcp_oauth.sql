-- Claude connector (remote MCP) with OAuth 2.1.
-- Claude registers itself as a client, the person pairs it with a short code shown in the app,
-- and the token endpoint mints a `sessions` row of kind 'mcp'. Codes are stored as SHA-256 hashes.

CREATE TABLE oauth_clients (
  client_id      TEXT PRIMARY KEY,
  client_name    TEXT CHECK (length(client_name) <= 100),
  redirect_uris  TEXT NOT NULL CHECK (length(redirect_uris) <= 4000),  -- JSON array
  created_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

-- Short-lived pairing codes created in the app ("Claude'a bağla"). One per user at a time.
CREATE TABLE mcp_link_codes (
  code_hash   TEXT PRIMARY KEY,
  user_id     TEXT NOT NULL UNIQUE REFERENCES users (id) ON DELETE CASCADE,
  expires_at  TEXT NOT NULL
);

-- OAuth authorization codes, valid for a few minutes and used once.
CREATE TABLE oauth_codes (
  code_hash       TEXT PRIMARY KEY,
  user_id         TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  client_id       TEXT NOT NULL REFERENCES oauth_clients (client_id) ON DELETE CASCADE,
  redirect_uri    TEXT NOT NULL,
  code_challenge  TEXT NOT NULL,
  expires_at      TEXT NOT NULL
);
CREATE INDEX oauth_codes_user_idx ON oauth_codes (user_id);
