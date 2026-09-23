CREATE TABLE IF NOT EXISTS installations (
  id TEXT PRIMARY KEY, auth_hash TEXT UNIQUE NOT NULL, device_token TEXT,
  environment TEXT NOT NULL DEFAULT 'production', badge INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS callbacks (
  id TEXT PRIMARY KEY, owner TEXT NOT NULL REFERENCES installations(id),
  secret_hash TEXT NOT NULL, config TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS callback_owner ON callbacks(owner);
CREATE TABLE IF NOT EXISTS events (
  id TEXT PRIMARY KEY, callback_id TEXT NOT NULL REFERENCES callbacks(id) ON DELETE CASCADE,
  created_at TEXT NOT NULL, status TEXT NOT NULL, detail TEXT NOT NULL,
  dedup_key TEXT, UNIQUE(callback_id, dedup_key)
);
CREATE INDEX IF NOT EXISTS event_callback ON events(callback_id, created_at);
CREATE INDEX IF NOT EXISTS event_created ON events(created_at);
CREATE TABLE IF NOT EXISTS receipts (
  callback_id TEXT NOT NULL REFERENCES callbacks(id) ON DELETE CASCADE,
  dedup_key TEXT NOT NULL, created_at TEXT NOT NULL, PRIMARY KEY(callback_id, dedup_key)
);
CREATE INDEX IF NOT EXISTS receipt_created ON receipts(created_at);
