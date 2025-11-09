-- Database schema for RSI Widget App

-- Instruments table
CREATE TABLE IF NOT EXISTS instrument (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  symbol TEXT NOT NULL UNIQUE,
  name TEXT,
  type TEXT NOT NULL,          -- stock|fx|crypto
  provider TEXT NOT NULL,      -- YF_PROTO|BINANCE|KRAKEN|TWELVE
  currency TEXT DEFAULT 'USD',
  exchange TEXT,
  created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
);

-- User devices table
CREATE TABLE IF NOT EXISTS device (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  fcm_token TEXT NOT NULL,
  platform TEXT NOT NULL,     -- ios|android
  app_version TEXT,
  os_version TEXT,
  device_model TEXT,
  is_active INTEGER NOT NULL DEFAULT 1,
  created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
  last_seen INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
);

-- Alert rules table
CREATE TABLE IF NOT EXISTS alert_rule (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id TEXT NOT NULL,
  symbol TEXT NOT NULL,
  timeframe TEXT NOT NULL,     -- 1m|5m|15m|1h|4h|1d
  rsi_period INTEGER NOT NULL DEFAULT 14,
  levels TEXT NOT NULL,        -- JSON array of levels
  mode TEXT NOT NULL,          -- cross|enter|exit
  hysteresis REAL NOT NULL DEFAULT 0.5,
  cooldown_sec INTEGER NOT NULL DEFAULT 600,
  active INTEGER NOT NULL DEFAULT 1,
  description TEXT,
  repeatable INTEGER NOT NULL DEFAULT 1,
  sound_enabled INTEGER NOT NULL DEFAULT 1,
  custom_sound TEXT,
  created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
  updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
);

-- Alert states table
CREATE TABLE IF NOT EXISTS alert_state (
  rule_id INTEGER PRIMARY KEY,
  last_rsi REAL,
  last_bar_ts INTEGER,
  last_fire_ts INTEGER,
  last_side TEXT,              -- above|below|between
  was_above_upper INTEGER,     -- for hysteresis
  was_below_lower INTEGER,      -- for hysteresis
  last_au REAL,                -- for incremental RSI
  last_ad REAL,                -- for incremental RSI
  updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
  FOREIGN KEY (rule_id) REFERENCES alert_rule(id) ON DELETE CASCADE
);

-- Alert events table
CREATE TABLE IF NOT EXISTS alert_event (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  rule_id INTEGER NOT NULL,
  user_id TEXT NOT NULL,
  symbol TEXT NOT NULL,
  ts INTEGER NOT NULL,
  rsi REAL NOT NULL,
  level REAL,
  side TEXT,                   -- cross_up|cross_down|enter_zone|exit_zone
  bar_ts INTEGER,
  message TEXT,
  is_read INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
  FOREIGN KEY (rule_id) REFERENCES alert_rule(id) ON DELETE CASCADE
);

-- RSI data table (cache)
CREATE TABLE IF NOT EXISTS rsi_data (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  symbol TEXT NOT NULL,
  timeframe TEXT NOT NULL,
  timestamp INTEGER NOT NULL,
  rsi REAL NOT NULL,
  close REAL NOT NULL,
  au REAL,                     -- for incremental calculation
  ad REAL,                     -- for incremental calculation
  created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
  UNIQUE(symbol, timeframe, timestamp)
);

-- Users table
CREATE TABLE IF NOT EXISTS user (
  id TEXT PRIMARY KEY,
  email TEXT UNIQUE,
  name TEXT,
  subscription_type TEXT DEFAULT 'free',  -- free|premium
  created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
  last_active INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
);

-- App settings table
CREATE TABLE IF NOT EXISTS app_settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
);

-- Indexes for query optimization
CREATE INDEX IF NOT EXISTS idx_device_user_id ON device(user_id);
CREATE INDEX IF NOT EXISTS idx_device_fcm_token ON device(fcm_token);
CREATE INDEX IF NOT EXISTS idx_device_active ON device(is_active);

CREATE INDEX IF NOT EXISTS idx_alert_rule_user_id ON alert_rule(user_id);
CREATE INDEX IF NOT EXISTS idx_alert_rule_symbol ON alert_rule(symbol);
CREATE INDEX IF NOT EXISTS idx_alert_rule_active ON alert_rule(active);
CREATE INDEX IF NOT EXISTS idx_alert_rule_symbol_timeframe ON alert_rule(symbol, timeframe);

CREATE INDEX IF NOT EXISTS idx_alert_event_rule_id ON alert_event(rule_id);
CREATE INDEX IF NOT EXISTS idx_alert_event_user_id ON alert_event(user_id);
CREATE INDEX IF NOT EXISTS idx_alert_event_ts ON alert_event(ts);
CREATE INDEX IF NOT EXISTS idx_alert_event_is_read ON alert_event(is_read);

CREATE INDEX IF NOT EXISTS idx_rsi_data_symbol_timeframe ON rsi_data(symbol, timeframe);
CREATE INDEX IF NOT EXISTS idx_rsi_data_timestamp ON rsi_data(timestamp);

-- Views for convenience
CREATE VIEW IF NOT EXISTS active_alerts AS
SELECT 
  ar.id,
  ar.user_id,
  ar.symbol,
  ar.timeframe,
  ar.rsi_period,
  ar.levels,
  ar.mode,
  ar.hysteresis,
  ar.cooldown_sec,
  ar.description,
  ars.last_rsi,
  ars.last_bar_ts,
  ars.last_fire_ts,
  ars.last_side
FROM alert_rule ar
LEFT JOIN alert_state ars ON ar.id = ars.rule_id
WHERE ar.active = 1;

CREATE VIEW IF NOT EXISTS user_devices AS
SELECT 
  d.id,
  d.user_id,
  d.fcm_token,
  d.platform,
  d.app_version,
  d.os_version,
  d.device_model,
  d.last_seen
FROM device d
WHERE d.is_active = 1;

-- Triggers for automatic updated_at update
CREATE TRIGGER IF NOT EXISTS update_alert_rule_updated_at
  AFTER UPDATE ON alert_rule
  BEGIN
    UPDATE alert_rule SET updated_at = strftime('%s', 'now') WHERE id = NEW.id;
  END;

CREATE TRIGGER IF NOT EXISTS update_alert_state_updated_at
  AFTER UPDATE ON alert_state
  BEGIN
    UPDATE alert_state SET updated_at = strftime('%s', 'now') WHERE rule_id = NEW.rule_id;
  END;

-- Functions for working with JSON (if supported)
-- SQLite doesn't have built-in JSON support, but simple functions can be used

-- Insert test data
INSERT OR IGNORE INTO instrument (symbol, name, type, provider, currency, exchange) VALUES
('AAPL', 'Apple Inc.', 'stock', 'YF_PROTO', 'USD', 'NASDAQ'),
('MSFT', 'Microsoft Corporation', 'stock', 'YF_PROTO', 'USD', 'NASDAQ'),
('GOOGL', 'Alphabet Inc.', 'stock', 'YF_PROTO', 'USD', 'NASDAQ'),
('TSLA', 'Tesla Inc.', 'stock', 'YF_PROTO', 'USD', 'NASDAQ'),
('EURUSD=X', 'Euro / US Dollar', 'fx', 'YF_PROTO', 'USD', 'FOREX'),
('GBPUSD=X', 'British Pound / US Dollar', 'fx', 'YF_PROTO', 'USD', 'FOREX'),
('USDJPY=X', 'US Dollar / Japanese Yen', 'fx', 'YF_PROTO', 'USD', 'FOREX'),
('BTC-USD', 'Bitcoin USD', 'crypto', 'YF_PROTO', 'USD', 'CRYPTO'),
('ETH-USD', 'Ethereum USD', 'crypto', 'YF_PROTO', 'USD', 'CRYPTO');

-- Default settings
INSERT OR IGNORE INTO app_settings (key, value) VALUES
('max_free_alerts', '5'),
('max_premium_alerts', '50'),
('default_rsi_period', '14'),
('default_levels', '[30, 70]'),
('default_hysteresis', '0.5'),
('default_cooldown', '600'),
('yahoo_rate_limit', '100'),
('fcm_rate_limit', '1000');
