-- One pending device migration per installation. lookup_hash is a hash of a value derived from the
-- migration code; payload is ciphertext the server cannot decrypt (the key never leaves the devices).
CREATE TABLE IF NOT EXISTS transfers (
  lookup_hash TEXT PRIMARY KEY, owner TEXT NOT NULL UNIQUE REFERENCES installations(id) ON DELETE CASCADE,
  payload TEXT NOT NULL, expires_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS transfer_expiry ON transfers(expires_at);
