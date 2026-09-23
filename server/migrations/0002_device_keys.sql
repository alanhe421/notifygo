ALTER TABLE installations ADD COLUMN device_key_hash TEXT;
CREATE UNIQUE INDEX installation_device_key ON installations(device_key_hash);
