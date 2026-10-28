CREATE TABLE orders (
  id TEXT PRIMARY KEY,
  environment TEXT NOT NULL CHECK(environment IN ('staging','production')),
  product TEXT NOT NULL CHECK(product = 'macmp4-pro-lifetime'),
  amount INTEGER NOT NULL CHECK(amount = 90),
  method TEXT NOT NULL CHECK(method IN ('ApplePay','Credit')),
  status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','paid','revoked')),
  email_hash TEXT NOT NULL,
  serial_hash TEXT NOT NULL UNIQUE,
  private_data TEXT NOT NULL,
  access_hash TEXT NOT NULL UNIQUE,
  checkout_hash TEXT NOT NULL UNIQUE,
  created_at INTEGER NOT NULL,
  paid_at INTEGER,
  provider_trade_no TEXT UNIQUE
);
CREATE INDEX orders_licenses ON orders(email_hash, serial_hash, environment);
CREATE TABLE rate_limits (key TEXT PRIMARY KEY, count INTEGER NOT NULL, expires_at INTEGER NOT NULL);
