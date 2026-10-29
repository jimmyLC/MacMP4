ALTER TABLE orders ADD COLUMN active_device_hash TEXT;
ALTER TABLE orders ADD COLUMN device_changed_at INTEGER;
ALTER TABLE orders ADD COLUMN email_sent_at INTEGER;
ALTER TABLE orders ADD COLUMN language TEXT;
