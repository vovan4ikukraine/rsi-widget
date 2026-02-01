-- Database schema for INDI CHARTS App
-- Exported from Cloudflare D1 (rsi-db prod) and formatted for idempotent execution

PRAGMA defer_foreign_keys=TRUE;

-- Tables (parent before children for FK)
CREATE TABLE IF NOT EXISTS device (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  fcm_token TEXT NOT NULL,
  platform TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  last_seen INTEGER
);

CREATE TABLE IF NOT EXISTS alert_rule (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id TEXT NOT NULL,
  symbol TEXT NOT NULL,
  timeframe TEXT NOT NULL,
  rsi_period INTEGER NOT NULL,
  levels TEXT NOT NULL,
  mode TEXT NOT NULL,
  cooldown_sec INTEGER NOT NULL,
  active INTEGER NOT NULL DEFAULT 1,
  created_at INTEGER NOT NULL,
  indicator TEXT NOT NULL DEFAULT 'rsi',
  stoch_d_period INTEGER,
  indicator_period INTEGER,
  period INTEGER,
  indicator_params TEXT,
  description TEXT,
  alert_on_close INTEGER DEFAULT 0,
  source TEXT DEFAULT 'custom'
);

CREATE TABLE IF NOT EXISTS alert_state (
  rule_id INTEGER PRIMARY KEY,
  last_rsi REAL,
  last_bar_ts INTEGER,
  last_fire_ts INTEGER,
  last_fire_ts_lower INTEGER,
  last_fire_ts_upper INTEGER,
  last_side TEXT,
  last_au REAL,
  last_ad REAL,
  last_indicator_value REAL,
  indicator_state TEXT,
  last_fire_bar_ts INTEGER,
  last_fire_bar_ts_lower INTEGER,
  last_fire_bar_ts_upper INTEGER,
  FOREIGN KEY (rule_id) REFERENCES alert_rule(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS alert_event (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  rule_id INTEGER NOT NULL,
  ts INTEGER NOT NULL,
  rsi REAL NOT NULL,
  level REAL,
  side TEXT,
  bar_ts INTEGER,
  symbol TEXT,
  indicator_value REAL,
  user_id TEXT,
  message TEXT,
  indicator TEXT,
  FOREIGN KEY (rule_id) REFERENCES alert_rule(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS user_watchlist (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id TEXT NOT NULL,
  symbol TEXT NOT NULL,
  created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
  UNIQUE(user_id, symbol)
);

CREATE TABLE IF NOT EXISTS user_preferences (
  user_id TEXT PRIMARY KEY,
  selected_symbol TEXT,
  selected_timeframe TEXT,
  rsi_period INTEGER,
  lower_level REAL,
  upper_level REAL,
  updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
);

CREATE TABLE IF NOT EXISTS candles_cache (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  symbol TEXT NOT NULL,
  timeframe TEXT NOT NULL,
  candles_json TEXT NOT NULL,
  cached_at INTEGER NOT NULL,
  provider TEXT DEFAULT 'yahoo',
  UNIQUE(symbol, timeframe)
);

CREATE TABLE IF NOT EXISTS api_request (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  endpoint TEXT NOT NULL,
  method TEXT NOT NULL,
  timestamp INTEGER NOT NULL,
  user_id TEXT,
  response_status INTEGER
);

CREATE TABLE IF NOT EXISTS error_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  type TEXT NOT NULL,
  message TEXT NOT NULL,
  error_class TEXT,
  timestamp TEXT NOT NULL,
  user_id TEXT,
  context TEXT,
  symbol TEXT,
  timeframe TEXT,
  additional_data TEXT
);

CREATE TABLE IF NOT EXISTS watchlist_alert_settings (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id TEXT NOT NULL,
  indicator TEXT NOT NULL,
  enabled INTEGER NOT NULL DEFAULT 0,
  timeframe TEXT NOT NULL DEFAULT '15m',
  period INTEGER NOT NULL DEFAULT 14,
  stoch_d_period INTEGER,
  mode TEXT NOT NULL DEFAULT 'cross',
  lower_level REAL NOT NULL DEFAULT 30,
  upper_level REAL NOT NULL DEFAULT 70,
  lower_level_enabled INTEGER NOT NULL DEFAULT 1,
  upper_level_enabled INTEGER NOT NULL DEFAULT 1,
  cooldown_sec INTEGER NOT NULL DEFAULT 600,
  repeatable INTEGER NOT NULL DEFAULT 1,
  on_close INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
  UNIQUE(user_id, indicator)
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_candles_cache_symbol_timeframe ON candles_cache(symbol, timeframe);
CREATE INDEX IF NOT EXISTS idx_candles_cache_cached_at ON candles_cache(cached_at);
CREATE INDEX IF NOT EXISTS idx_api_request_timestamp ON api_request(timestamp);
CREATE INDEX IF NOT EXISTS idx_api_request_endpoint ON api_request(endpoint);
CREATE INDEX IF NOT EXISTS idx_error_log_type ON error_log(type);
CREATE INDEX IF NOT EXISTS idx_error_log_timestamp ON error_log(timestamp);
CREATE INDEX IF NOT EXISTS idx_error_log_user_id ON error_log(user_id);
