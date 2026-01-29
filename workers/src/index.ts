import { Hono } from 'hono';
import { cors } from 'hono/cors';
import { IndicatorEngine } from './rsi-engine';
import { FcmService } from './fcm-service';
import { YahooService } from './yahoo-service';
import { BinanceService } from './binance-service';
import { DataProviderService } from './data-provider-service';
import { Logger } from './logger';
import { adminAuthMiddleware } from './admin/auth';
import { getAdminStats, getUsers } from './admin/stats';
import { getProviders, updateProviders } from './admin/providers';
import { logError, getErrorGroups, getErrorHistory } from './admin/errors';

export interface Env {
    KV: KVNamespace;
    DB: D1Database;
    FCM_SERVICE_ACCOUNT_JSON: string; // Service Account JSON for FCM V1 API
    FCM_PROJECT_ID: string; // Firebase project ID
    YAHOO_ENDPOINT: string;
    [key: string]: any;
}

const app = new Hono<{ Bindings: Env }>();

async function ensureTables(db: D1Database, env?: any) {
    await db.prepare(`
      CREATE TABLE IF NOT EXISTS device (
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        fcm_token TEXT NOT NULL,
        platform TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    `).run();

    // Migration: Add last_seen column if it doesn't exist
    try {
        await db.prepare(`ALTER TABLE device ADD COLUMN last_seen INTEGER`).run();
    } catch (e: any) {
        if (!e.message?.includes('duplicate column')) {
            Logger.warn('Migration: last_seen column may already exist', env);
        }
    }

    await db.prepare(`
      CREATE TABLE IF NOT EXISTS alert_rule (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id TEXT NOT NULL,
        symbol TEXT NOT NULL,
        timeframe TEXT NOT NULL,
        indicator TEXT NOT NULL DEFAULT 'rsi',
        period INTEGER NOT NULL DEFAULT 14,
        indicator_params TEXT,
        rsi_period INTEGER,
        levels TEXT NOT NULL,
        mode TEXT NOT NULL,
        cooldown_sec INTEGER NOT NULL,
        active INTEGER NOT NULL DEFAULT 1,
        created_at INTEGER NOT NULL
      )
    `).run();

    // Migration: Add indicator and period columns if they don't exist
    try {
        await db.prepare(`ALTER TABLE alert_rule ADD COLUMN indicator TEXT`).run();
    } catch (e: any) {
        // Column already exists, ignore
        if (!e.message?.includes('duplicate column')) {
            Logger.warn('Migration: indicator column may already exist', env);
        }
    }

    try {
        await db.prepare(`ALTER TABLE alert_rule ADD COLUMN period INTEGER`).run();
    } catch (e: any) {
        if (!e.message?.includes('duplicate column')) {
            Logger.warn('Migration: period column may already exist', env);
        }
    }

    try {
        await db.prepare(`ALTER TABLE alert_rule ADD COLUMN indicator_params TEXT`).run();
    } catch (e: any) {
        if (!e.message?.includes('duplicate column')) {
            Logger.warn('Migration: indicator_params column may already exist', env);
        }
    }

    // Migration: Add description column if it doesn't exist
    try {
        await db.prepare(`ALTER TABLE alert_rule ADD COLUMN description TEXT`).run();
    } catch (e: any) {
        if (!e.message?.includes('duplicate column')) {
            Logger.warn('Migration: description column may already exist', env);
        }
    }

    // Migration: Add alert_on_close column (0 = crossing / 1 = on candle close only)
    try {
        await db.prepare(`ALTER TABLE alert_rule ADD COLUMN alert_on_close INTEGER DEFAULT 0`).run();
    } catch (e: any) {
        if (!e.message?.includes('duplicate column')) {
            Logger.warn('Migration: alert_on_close column may already exist', env);
        }
    }

    // Migration: Add source column ('watchlist' or 'custom') for notification differentiation
    try {
        await db.prepare(`ALTER TABLE alert_rule ADD COLUMN source TEXT DEFAULT 'custom'`).run();
    } catch (e: any) {
        if (!e.message?.includes('duplicate column')) {
            Logger.warn('Migration: source column may already exist', env);
        }
    }

    // Migration: Copy rsi_period to period for existing records
    await db.prepare(`
      UPDATE alert_rule 
      SET period = rsi_period, indicator = 'rsi'
      WHERE period IS NULL OR indicator IS NULL
    `).run();

    await db.prepare(`
      CREATE TABLE IF NOT EXISTS user_watchlist (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id TEXT NOT NULL,
        symbol TEXT NOT NULL,
        created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
        UNIQUE(user_id, symbol)
      )
    `).run();

    await db.prepare(`
      CREATE TABLE IF NOT EXISTS user_preferences (
        user_id TEXT PRIMARY KEY,
        selected_symbol TEXT,
        selected_timeframe TEXT,
        rsi_period INTEGER,
        lower_level REAL,
        upper_level REAL,
        updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
      )
    `).run();

    // Table for storing watchlist alert settings per user per indicator
    await db.prepare(`
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
      )
    `).run();

    await db.prepare(`
      CREATE TABLE IF NOT EXISTS alert_state (
        rule_id INTEGER PRIMARY KEY,
        last_indicator_value REAL,
        indicator_state TEXT,
        last_bar_ts INTEGER,
        last_fire_ts INTEGER,
        last_side TEXT,
        last_rsi REAL,
        last_au REAL,
        last_ad REAL,
        FOREIGN KEY(rule_id) REFERENCES alert_rule(id) ON DELETE CASCADE
      )
    `).run();

    // Migration: Add new columns if they don't exist
    try {
        await db.prepare(`ALTER TABLE alert_state ADD COLUMN last_indicator_value REAL`).run();
    } catch (e: any) {
        if (!e.message?.includes('duplicate column')) {
            Logger.warn('Migration: last_indicator_value column may already exist', env);
        }
    }

    try {
        await db.prepare(`ALTER TABLE alert_state ADD COLUMN indicator_state TEXT`).run();
    } catch (e: any) {
        if (!e.message?.includes('duplicate column')) {
            Logger.warn('Migration: indicator_state column may already exist', env);
        }
    }

    // Migration: Copy last_rsi to last_indicator_value for existing records
    await db.prepare(`
      UPDATE alert_state 
      SET last_indicator_value = last_rsi
      WHERE last_indicator_value IS NULL AND last_rsi IS NOT NULL
    `).run();

    // Migration: Convert last_au/last_ad to indicator_state JSON
    const states = await db.prepare(`SELECT rule_id, last_au, last_ad FROM alert_state WHERE last_au IS NOT NULL OR last_ad IS NOT NULL`).all();
    for (const state of states.results as any[]) {
        const stateJson = JSON.stringify({
            au: state.last_au,
            ad: state.last_ad
        });
        await db.prepare(`
          UPDATE alert_state 
          SET indicator_state = ?
          WHERE rule_id = ? AND indicator_state IS NULL
        `).bind(stateJson, state.rule_id).run();
    }

    await db.prepare(`
      CREATE TABLE IF NOT EXISTS alert_event (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        rule_id INTEGER NOT NULL,
        ts INTEGER NOT NULL,
        indicator_value REAL NOT NULL,
        indicator TEXT,
        rsi REAL,
        level REAL,
        side TEXT,
        bar_ts INTEGER,
        symbol TEXT,
        FOREIGN KEY(rule_id) REFERENCES alert_rule(id) ON DELETE CASCADE
      )
    `).run();

    // Migration: Add new columns if they don't exist
    try {
        await db.prepare(`ALTER TABLE alert_event ADD COLUMN indicator_value REAL`).run();
    } catch (e: any) {
        if (!e.message?.includes('duplicate column')) {
            Logger.warn('Migration: indicator_value column may already exist', env);
        }
    }

    try {
        await db.prepare(`ALTER TABLE alert_event ADD COLUMN indicator TEXT`).run();
    } catch (e: any) {
        if (!e.message?.includes('duplicate column')) {
            Logger.warn('Migration: indicator column may already exist', env);
        }
    }

    // Migration: Copy rsi to indicator_value for existing records
    await db.prepare(`
      UPDATE alert_event 
      SET indicator_value = rsi, indicator = 'rsi'
      WHERE indicator_value IS NULL AND rsi IS NOT NULL
    `).run();

    // Create candles cache table (replaces KV for candles cache - much cheaper)
    await db.prepare(`
      CREATE TABLE IF NOT EXISTS candles_cache (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        symbol TEXT NOT NULL,
        timeframe TEXT NOT NULL,
        candles_json TEXT NOT NULL,
        cached_at INTEGER NOT NULL,
        UNIQUE(symbol, timeframe)
      )
    `).run();

    // Migration: Add provider column if it doesn't exist
    try {
        await db.prepare(`ALTER TABLE candles_cache ADD COLUMN provider TEXT DEFAULT 'yahoo'`).run();
    } catch (e: any) {
        if (!e.message?.includes('duplicate column')) {
            Logger.warn('Migration: provider column may already exist', env);
        }
    }

    // Migration: Set default provider for existing records
    await db.prepare(`
      UPDATE candles_cache 
      SET provider = 'yahoo'
      WHERE provider IS NULL
    `).run();

    // Create indexes for candles cache
    try {
        await db.prepare(`CREATE INDEX IF NOT EXISTS idx_candles_cache_symbol_timeframe ON candles_cache(symbol, timeframe)`).run();
        await db.prepare(`CREATE INDEX IF NOT EXISTS idx_candles_cache_cached_at ON candles_cache(cached_at)`).run();
    } catch (e: any) {
        // Indexes may already exist, ignore
    }

    // Create error log table
    await db.prepare(`
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
      )
    `).run();

    // Create indexes for error log
    try {
        await db.prepare(`CREATE INDEX IF NOT EXISTS idx_error_log_type ON error_log(type)`).run();
        await db.prepare(`CREATE INDEX IF NOT EXISTS idx_error_log_timestamp ON error_log(timestamp)`).run();
        await db.prepare(`CREATE INDEX IF NOT EXISTS idx_error_log_user_id ON error_log(user_id)`).run();
    } catch (e: any) {
        // Indexes may already exist, ignore
    }
}

/**
 * Обновить активность устройств пользователя (отметить как активные)
 * Вызывается при пользовательских действиях (не фоновых)
 */
async function updateDeviceActivity(db: D1Database, userId: string) {
    try {
        const now = Math.floor(Date.now() / 1000);
        await db.prepare(`
            UPDATE device 
            SET last_seen = ? 
            WHERE user_id = ?
        `).bind(now, userId).run();
    } catch (error) {
        // Ignore errors - this is non-critical
        Logger.warn('Failed to update device activity', undefined);
    }
}

// CORS middleware
app.use('*', cors({
    origin: '*',
    allowHeaders: ['Content-Type', 'Authorization', 'X-Admin-API-Key'],
    allowMethods: ['GET', 'POST', 'PUT', 'DELETE', 'OPTIONS'],
}));

// Root endpoint
app.get('/', (c) => {
    return c.json({
        service: 'RSI Widget API',
        version: '1.0.0',
        status: 'ok',
        endpoints: {
            yahoo: {
                candles: 'GET /yf/candles?symbol=SYMBOL&tf=TIMEFRAME',
                quote: 'GET /yf/quote?symbol=SYMBOL',
                info: 'GET /yf/info?symbol=SYMBOL',
                search: 'GET /yf/search?q=QUERY'
            },
            device: {
                register: 'POST /device/register'
            },
            alerts: {
                create: 'POST /alerts/create',
                get: 'GET /alerts/:userId',
                update: 'PUT /alerts/:ruleId',
                delete: 'DELETE /alerts/:ruleId?hard=true',
                check: 'POST /alerts/check'
            }
        }
    });
});

// Proxy for Yahoo Finance (with Binance fallback for crypto)
app.get('/yf/candles', async (c) => {
    try {
        const { symbol, tf, since, limit, userId } = c.req.query();

        if (!symbol || !tf) {
            return c.json({ error: 'Missing symbol or timeframe' }, 400);
        }

        const db = c.env?.DB as D1Database;
        const yahooService = new YahooService(c.env?.YAHOO_ENDPOINT as string || '');
        const binanceService = new BinanceService();
        const dataProviderService = new DataProviderService(yahooService, binanceService, db);

        // Update device activity if userId is provided (user opening app/refreshing data)
        // Use fire-and-forget to not block the response
        if (userId && db) {
            // Don't await - this is non-critical and shouldn't slow down the request
            updateDeviceActivity(db, userId).catch(() => {
                // Silently ignore errors - activity tracking is not critical
            });
        }

        // Use DataProviderService (handles cache, Binance for crypto, Yahoo fallback)
        // Check cache first to determine if it's a cache hit
        const cached = await dataProviderService.getCachedCandles(symbol, tf);
        const isCacheHit = cached !== null && cached.candles.length > 0;

        const { candles, provider } = await dataProviderService.getCandles(symbol, tf, {
            since: since ? parseInt(since) : undefined,
            limit: limit ? parseInt(limit) : 1000,
        });

        // Apply limit if specified (for cached data that might exceed limit)
        let result = candles;
        if (limit) {
            const limitNum = parseInt(limit);
            result = candles.slice(-limitNum);
        }

        // Log cache hit/miss
        if (isCacheHit) {
            Logger.cacheHit(symbol, tf, result.length, c.env);
        } else {
            Logger.cacheMiss(symbol, tf, c.env);
            Logger.cacheSave(symbol, tf, candles.length, c.env);
        }

        // Add debug info if requested
        const debug = c.req.query('debug') === 'true';
        if (debug) {
            const timestamp = new Date().toISOString();
            return c.json({
                data: result,
                meta: {
                    source: isCacheHit ? 'cache' : provider,
                    provider: provider,
                    symbol: symbol,
                    timeframe: tf,
                    count: result.length,
                    timestamp: timestamp,
                }
            });
        }

        // Set header to indicate data source
        c.header('X-Data-Source', isCacheHit ? 'cache' : provider);
        c.header('X-Data-Provider', provider);
        return c.json(result);
    } catch (error) {
        Logger.error('Error fetching candles:', error, c.env);
        return c.json({ error: 'Failed to fetch candles' }, 500);
    }
});

// Get current price (with Binance for crypto)
app.get('/yf/quote', async (c) => {
    try {
        const { symbol } = c.req.query();

        if (!symbol) {
            return c.json({ error: 'Missing symbol' }, 400);
        }

        const db = c.env?.DB as D1Database;
        const yahooService = new YahooService(c.env?.YAHOO_ENDPOINT as string || '');
        const binanceService = new BinanceService();
        const dataProviderService = new DataProviderService(yahooService, binanceService, db);

        const { quote, provider } = await dataProviderService.getQuote(symbol);

        // Set header to indicate provider
        c.header('X-Data-Provider', provider);
        return c.json(quote);
    } catch (error) {
        Logger.error('Error fetching quote:', error, c.env);
        return c.json({ error: 'Failed to fetch quote' }, 500);
    }
});

// Symbol information (with Binance for crypto)
app.get('/yf/info', async (c) => {
    try {
        const { symbol } = c.req.query();

        if (!symbol) {
            return c.json({ error: 'Missing symbol' }, 400);
        }

        const db = c.env?.DB as D1Database;
        const yahooService = new YahooService(c.env?.YAHOO_ENDPOINT as string || '');
        const binanceService = new BinanceService();
        const dataProviderService = new DataProviderService(yahooService, binanceService, db);

        const { info, provider } = await dataProviderService.getSymbolInfo(symbol);

        // Set header to indicate provider
        c.header('X-Data-Provider', provider);
        return c.json(info);
    } catch (error) {
        Logger.error('Error fetching symbol info:', error, c.env);
        return c.json({ error: 'Failed to fetch symbol info' }, 500);
    }
});

// Search symbols
app.get('/yf/search', async (c) => {
    try {
        const { q } = c.req.query();

        if (!q) {
            return c.json({ error: 'Missing query' }, 400);
        }

        const yahooService = new YahooService(c.env?.YAHOO_ENDPOINT as string || '');
        const results = await yahooService.searchSymbols(q);

        return c.json(results);
    } catch (error) {
        Logger.error('Error searching symbols:', error, c.env);
        return c.json({ error: 'Failed to search symbols' }, 500);
    }
});

// Device registration
app.post('/device/register', async (c) => {
    try {
        const { deviceId, fcmToken, platform, userId } = await c.req.json();

        if (!deviceId || !fcmToken || !platform || !userId) {
            return c.json({ error: 'Missing required fields' }, 400);
        }

        const db = c.env?.DB as D1Database;
        await ensureTables(db);

        const nowMs = Date.now();
        const nowSec = Math.floor(nowMs / 1000);
        const result = await db.prepare(`
      INSERT OR REPLACE INTO device (id, user_id, fcm_token, platform, created_at, last_seen)
      VALUES (?, ?, ?, ?, ?, ?)
    `).bind(deviceId, userId, fcmToken, platform, nowMs, nowSec).run();

        return c.json({ success: true, id: result.meta.last_row_id });
    } catch (error) {
        Logger.error('Error registering device:', error, c.env);
        return c.json({ error: 'Failed to register device' }, 500);
    }
});

// Create alert rule
app.post('/alerts/create', async (c) => {
    try {
        const {
            userId,
            symbol,
            timeframe,
            indicator,
            period,
            rsiPeriod,  // Deprecated, kept for backward compatibility
            indicatorParams,
            levels,
            mode,
            cooldownSec,
            description,  // Optional description (used for watchlist alerts: "WATCHLIST:")
            alertOnClose,  // Optional: true = alert only on candle close, false = on crossing (default)
            source  // Optional: 'watchlist' or 'custom' (default) - for notification differentiation
        } = await c.req.json();

        if (!userId || !symbol || !timeframe || !levels) {
            return c.json({ error: 'Missing required fields' }, 400);
        }

        // Validate symbol (max 20 chars, alphanumeric and common symbols only)
        if (typeof symbol !== 'string' || symbol.length > 20 || symbol.length < 1) {
            return c.json({ error: 'Invalid symbol: must be 1-20 characters' }, 400);
        }
        if (!/^[A-Z0-9.\-=]+$/i.test(symbol)) {
            return c.json({ error: 'Invalid symbol: contains invalid characters' }, 400);
        }

        // Validate timeframe
        const validTimeframes = ['1m', '5m', '15m', '1h', '4h', '1d'];
        if (!validTimeframes.includes(timeframe)) {
            return c.json({ error: `Invalid timeframe: must be one of ${validTimeframes.join(', ')}` }, 400);
        }

        // Validate indicator (default to 'rsi')
        const alertIndicator = indicator || 'rsi';
        const validIndicators = ['rsi', 'stoch', 'williams'];
        if (!validIndicators.includes(alertIndicator)) {
            return c.json({ error: `Invalid indicator: must be one of ${validIndicators.join(', ')}` }, 400);
        }

        // Validate period (1-100) - universal period for all indicators
        const alertPeriod = period || rsiPeriod || (alertIndicator === 'stoch' ? 14 : 14);
        if (!Number.isInteger(alertPeriod) || alertPeriod < 1 || alertPeriod > 100) {
            return c.json({ error: 'Invalid period: must be between 1 and 100' }, 400);
        }

        // Validate indicator parameters if provided
        let indicatorParamsJson: string | null = null;
        if (indicatorParams) {
            if (typeof indicatorParams !== 'object') {
                return c.json({ error: 'Invalid indicatorParams: must be an object' }, 400);
            }
            indicatorParamsJson = JSON.stringify(indicatorParams);
        }

        // Validate levels
        // Levels array should have 2 elements [lower, upper] with null for disabled levels
        // For Williams %R: -99 to -1, for others: 1 to 99
        if (!Array.isArray(levels) || levels.length === 0 || levels.length > 2) {
            return c.json({ error: 'Invalid levels: must be array of 1-2 elements [lower, upper] with null for disabled' }, 400);
        }
        const isWilliams = alertIndicator === 'williams';
        const minLevel = isWilliams ? -99 : 1;
        const maxLevel = isWilliams ? -1 : 99;
        
        // Filter out null values and validate
        const validLevels: number[] = [];
        for (let i = 0; i < levels.length; i++) {
            const level = levels[i];
            if (level === null || level === undefined) {
                continue; // Skip null/undefined (disabled level)
            }
            if (typeof level !== 'number' || !isFinite(level)) {
                return c.json({ error: `Invalid level at index ${i}: must be a finite number or null` }, 400);
            }
            if (level < minLevel || level > maxLevel) {
                return c.json({ 
                    error: `Invalid level at index ${i}: must be number between ${minLevel} and ${maxLevel}${isWilliams ? ' (Williams %R range)' : ''} or null` 
                }, 400);
            }
            validLevels.push(level);
        }
        
        if (validLevels.length === 0) {
            return c.json({ error: 'At least one level must be enabled (not null)' }, 400);
        }

        // Validate mode
        const validModes = ['cross', 'enter', 'exit'];
        const alertMode = mode || 'cross';
        if (!validModes.includes(alertMode)) {
            return c.json({ error: `Invalid mode: must be one of ${validModes.join(', ')}` }, 400);
        }

        // Validate cooldown (0-86400 seconds = 0-24 hours)
        const cooldown = cooldownSec || 600;
        if (!Number.isInteger(cooldown) || cooldown < 0 || cooldown > 86400) {
            return c.json({ error: 'Invalid cooldown: must be between 0 and 86400 seconds (24 hours)' }, 400);
        }

        const alertOnCloseVal = alertOnClose === true || alertOnClose === 1 ? 1 : 0;
        // Validate source (default to 'custom')
        const alertSource = source === 'watchlist' ? 'watchlist' : 'custom';

        const db = c.env?.DB as D1Database;
        await ensureTables(db);

        const result = await db.prepare(`
      INSERT INTO alert_rule (
        user_id, symbol, timeframe, indicator, period, indicator_params, rsi_period, levels, mode, 
        cooldown_sec, active, created_at, description, alert_on_close, source
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?)
    `).bind(
            userId, symbol.toUpperCase(), timeframe, alertIndicator, alertPeriod,
            indicatorParamsJson, alertPeriod, // rsi_period for backward compatibility
            JSON.stringify(validLevels), alertMode,
            cooldown, Date.now(), description || null, alertOnCloseVal, alertSource
        ).run();

        // Update device activity (user action)
        await updateDeviceActivity(db, userId);

        return c.json({ success: true, id: result.meta.last_row_id });
    } catch (error) {
        Logger.error('Error creating alert rule:', error, c.env);
        return c.json({ error: 'Failed to create alert rule' }, 500);
    }
});

// Get user rules
app.get('/alerts/:userId', async (c) => {
    try {
        const userId = c.req.param('userId');

        const db = c.env?.DB as D1Database;
        await ensureTables(db);

        const result = await db.prepare(`
      SELECT * FROM alert_rule WHERE user_id = ? AND active = 1
    `).bind(userId).all();

        // Update device activity (user action)
        await updateDeviceActivity(db, userId);

        return c.json({ rules: result.results });
    } catch (error) {
        Logger.error('Error fetching alert rules:', error, c.env);
        return c.json({ error: 'Failed to fetch alert rules' }, 500);
    }
});

// Update rule
app.put('/alerts/:ruleId', async (c) => {
    try {
        const ruleId = c.req.param('ruleId');
        const { userId, ...updates } = await c.req.json();

        if (!userId) {
            return c.json({ error: 'Missing userId' }, 400);
        }

        const db = c.env?.DB as D1Database;
        await ensureTables(db);

        // Verify that the alert belongs to the user
        const existing = await db.prepare(`
            SELECT user_id, indicator FROM alert_rule WHERE id = ?
        `).bind(ruleId).first<{ user_id: string; indicator: string }>();

        if (!existing) {
            return c.json({ error: 'Alert not found' }, 404);
        }

        if (existing.user_id !== userId) {
            return c.json({ error: 'Unauthorized: alert belongs to different user' }, 403);
        }

        // Validate updates if present
        if (updates.symbol !== undefined) {
            if (typeof updates.symbol !== 'string' || updates.symbol.length > 20 || updates.symbol.length < 1) {
                return c.json({ error: 'Invalid symbol: must be 1-20 characters' }, 400);
            }
            if (!/^[A-Z0-9.\-=]+$/i.test(updates.symbol)) {
                return c.json({ error: 'Invalid symbol: contains invalid characters' }, 400);
            }
            updates.symbol = updates.symbol.toUpperCase();
        }

        if (updates.timeframe !== undefined) {
            const validTimeframes = ['1m', '5m', '15m', '1h', '4h', '1d'];
            if (!validTimeframes.includes(updates.timeframe)) {
                return c.json({ error: `Invalid timeframe: must be one of ${validTimeframes.join(', ')}` }, 400);
            }
        }

        if (updates.indicator !== undefined) {
            const validIndicators = ['rsi', 'stoch', 'williams'];
            if (!validIndicators.includes(updates.indicator)) {
                return c.json({ error: `Invalid indicator: must be one of ${validIndicators.join(', ')}` }, 400);
            }
        }

        if (updates.period !== undefined) {
            if (!Number.isInteger(updates.period) || updates.period < 1 || updates.period > 100) {
                return c.json({ error: 'Invalid period: must be between 1 and 100' }, 400);
            }
        }

        if (updates.indicatorParams !== undefined) {
            if (typeof updates.indicatorParams !== 'object') {
                return c.json({ error: 'Invalid indicatorParams: must be an object' }, 400);
            }
            updates.indicatorParams = JSON.stringify(updates.indicatorParams);
        }

        if (updates.rsi_period !== undefined) {
            if (!Number.isInteger(updates.rsi_period) || updates.rsi_period < 1 || updates.rsi_period > 100) {
                return c.json({ error: 'Invalid RSI period: must be between 1 and 100' }, 400);
            }
            // Also update period for consistency
            if (updates.period === undefined) {
                updates.period = updates.rsi_period;
            }
        }

        if (updates.levels !== undefined) {
            // Levels array should have 2 elements [lower, upper] with null for disabled levels
            if (!Array.isArray(updates.levels) || updates.levels.length === 0 || updates.levels.length > 2) {
                return c.json({ error: 'Invalid levels: must be array of 1-2 elements [lower, upper] with null for disabled' }, 400);
            }
            // Determine indicator type for validation (use updates.indicator if provided, otherwise check existing alert)
            const updateIndicator = updates.indicator || existing.indicator || 'rsi';
            const isWilliams = updateIndicator === 'williams';
            const minLevel = isWilliams ? -99 : 1;
            const maxLevel = isWilliams ? -1 : 99;
            
            // Filter out null values and validate
            const validLevels: number[] = [];
            for (let i = 0; i < updates.levels.length; i++) {
                const level = updates.levels[i];
                if (level === null || level === undefined) {
                    continue; // Skip null/undefined (disabled level)
                }
                if (typeof level !== 'number' || !isFinite(level)) {
                    return c.json({ error: `Invalid level at index ${i}: must be a finite number or null` }, 400);
                }
                if (level < minLevel || level > maxLevel) {
                    return c.json({ 
                        error: `Invalid level at index ${i}: must be number between ${minLevel} and ${maxLevel}${isWilliams ? ' (Williams %R range)' : ''} or null` 
                    }, 400);
                }
                validLevels.push(level);
            }
            
            if (validLevels.length === 0) {
                return c.json({ error: 'At least one level must be enabled (not null)' }, 400);
            }
            
            updates.levels = JSON.stringify(validLevels);
        }

        if (updates.mode !== undefined) {
            const validModes = ['cross', 'enter', 'exit'];
            if (!validModes.includes(updates.mode)) {
                return c.json({ error: `Invalid mode: must be one of ${validModes.join(', ')}` }, 400);
            }
        }

        if (updates.cooldown_sec !== undefined) {
            if (!Number.isInteger(updates.cooldown_sec) || updates.cooldown_sec < 0 || updates.cooldown_sec > 86400) {
                return c.json({ error: 'Invalid cooldown: must be between 0 and 86400 seconds' }, 400);
            }
        }

        if (updates.alert_on_close !== undefined) {
            updates.alert_on_close = (updates.alert_on_close === true || updates.alert_on_close === 1) ? 1 : 0;
        }

        const fields = Object.keys(updates)
            .filter(key => key !== 'id' && key !== 'user_id')
            .map(key => `${key} = ?`)
            .join(', ');

        if (fields.length === 0) {
            return c.json({ error: 'No valid fields to update' }, 400);
        }

        const values = Object.values(updates).filter((_, i) => {
            const key = Object.keys(updates)[i];
            return key !== 'id' && key !== 'user_id';
        });
        values.push(ruleId);

        await db.prepare(`
      UPDATE alert_rule SET ${fields} WHERE id = ?
    `).bind(...values).run();

        // Update device activity (user action)
        await updateDeviceActivity(db, userId);

        return c.json({ success: true });
    } catch (error) {
        Logger.error('Error updating alert rule:', error, c.env);
        return c.json({ error: 'Failed to update alert rule' }, 500);
    }
});

// Delete rule
app.delete('/alerts/:ruleId', async (c) => {
    try {
        const ruleId = c.req.param('ruleId');
        const { userId } = await c.req.json();

        if (!userId) {
            return c.json({ error: 'Missing userId' }, 400);
        }

        const db = c.env?.DB as D1Database;
        await ensureTables(db);

        // Verify that the alert belongs to the user
        const existing = await db.prepare(`
            SELECT user_id FROM alert_rule WHERE id = ?
        `).bind(ruleId).first<{ user_id: string }>();

        if (!existing) {
            return c.json({ error: 'Alert not found' }, 404);
        }

        if (existing.user_id !== userId) {
            return c.json({ error: 'Unauthorized: alert belongs to different user' }, 403);
        }

        const hard = c.req.query('hard');

        if (hard === 'true') {
            await db.prepare(`DELETE FROM alert_event WHERE rule_id = ?`).bind(ruleId).run();
            await db.prepare(`DELETE FROM alert_state WHERE rule_id = ?`).bind(ruleId).run();
            await db.prepare(`DELETE FROM alert_rule WHERE id = ?`).bind(ruleId).run();
        } else {
            await db.prepare(`
        UPDATE alert_rule SET active = 0 WHERE id = ?
      `).bind(ruleId).run();
        }

        // Update device activity (user action)
        await updateDeviceActivity(db, userId);

        return c.json({ success: true });
    } catch (error) {
        Logger.error('Error deleting alert rule:', error, c.env);
        return c.json({ error: 'Failed to delete alert rule' }, 500);
    }
});

// Force alert check
app.post('/alerts/check', async (c) => {
    try {
        const { symbols, timeframes } = await c.req.json();

        if (!symbols || !timeframes) {
            return c.json({ error: 'Missing symbols or timeframes' }, 400);
        }

        const db = c.env?.DB as D1Database;
        await ensureTables(db);

        // Note: This endpoint is deprecated, use CRON job instead
        return c.json({ error: 'This endpoint is deprecated. Use CRON job for alert checking.' }, 400);
    } catch (error) {
        Logger.error('Error checking alerts:', error, c.env);
        return c.json({ error: 'Failed to check alerts' }, 500);
    }
});

// Cron job for checking alerts
const worker: ExportedHandler<Env> = {
    fetch: app.fetch,
    scheduled: async (_controller: ScheduledController, env: Env, _ctx: ExecutionContext) => {
        try {
            const db = env.DB;

            // Quick check: use LIMIT 1 to check if any active rules exist
            // This is faster than COUNT(*) because it stops after finding first match
            const activeRulesCheck = await db.prepare(`
                SELECT 1 FROM alert_rule WHERE active = 1 LIMIT 1
            `).first();

            if (!activeRulesCheck) {
                // No active rules, skip all processing immediately (no ensureTables, no RSI checks)
                Logger.debug('Scheduled RSI check skipped: no active alert rules', env);
                return;
            }

            // If we got here, there are active rules - now get the count for logging
            const countResult = await db.prepare(`
                SELECT COUNT(*) as count FROM alert_rule WHERE active = 1
            `).first<{ count: number }>();

            const activeCount = countResult?.count || 0;

            Logger.info(`Running scheduled RSI check for ${activeCount} active rule(s)...`, env);

            // Check FCM configuration
            if (!env.FCM_SERVICE_ACCOUNT_JSON || env.FCM_SERVICE_ACCOUNT_JSON.trim() === '') {
                Logger.error('FCM_SERVICE_ACCOUNT_JSON is not set! Please set it via: wrangler secret put FCM_SERVICE_ACCOUNT_JSON', undefined, env);
                Logger.error('Paste the entire Service Account JSON file content', undefined, env);
                return;
            }

            if (!env.FCM_PROJECT_ID || env.FCM_PROJECT_ID.trim() === '') {
                Logger.error('FCM_PROJECT_ID is not set! Please set it in wrangler.toml [vars]', undefined, env);
                return;
            }

            await ensureTables(db);
            const yahooService = new YahooService(env.YAHOO_ENDPOINT);
            const binanceService = new BinanceService();
            const dataProviderService = new DataProviderService(yahooService, binanceService, db);
            const indicatorEngine = new IndicatorEngine(db, dataProviderService);
            const fcmService = new FcmService(env.FCM_SERVICE_ACCOUNT_JSON, env.FCM_PROJECT_ID, env.KV, env.DB);

            // Check regular alerts (custom alerts created by users)
            if (activeCount > 0) {
                // Get active rules (we already know there are some)
                const rules = await indicatorEngine.getActiveRules();

                // Group by symbols and timeframes - this automatically groups user requests
                // If 100 users have alerts for AAPL 15m, we check it once, not 100 times
                const groupedRules = indicatorEngine.groupRulesBySymbolTimeframe(rules);
                const symbolTimeframePairs = Object.entries(groupedRules);
                const startTime = Date.now();

                // Rate limiting: max 3.5 requests per second to Yahoo Finance (balanced between speed and safety)
                // Delay only applies to cache misses (real Yahoo Finance requests)
                const RATE_LIMIT_DELAY_MS = 285; // ~3.5 requests per second (balanced)
                let yahooRequestCount = 0;
                let cacheHitCount = 0;
                let cacheMissCount = 0;
                let totalTriggers = 0;

                // Safety limit: process max 200 symbol/timeframe pairs per cron run
                // This prevents CPU burst and keeps wall time under Cloudflare's 30-60s limit
                // Remaining pairs will be processed in next cron run (runs every minute)
                const MAX_PAIRS_PER_RUN = 200;
                const pairsToProcess = symbolTimeframePairs.slice(0, MAX_PAIRS_PER_RUN);
                
                if (symbolTimeframePairs.length > MAX_PAIRS_PER_RUN) {
                    Logger.warn(`Processing ${MAX_PAIRS_PER_RUN} of ${symbolTimeframePairs.length} pairs to prevent CPU burst`, env);
                }

                // Check each symbol/timeframe with optimized rate limiting
                for (let pairIndex = 0; pairIndex < pairsToProcess.length; pairIndex++) {
                    const [key, rules] = pairsToProcess[pairIndex];
                    const [symbol, timeframe] = key.split('|');

                    // Add delay between Yahoo Finance requests (only for cache misses)
                    if (yahooRequestCount > 0) {
                        await new Promise(resolve => setTimeout(resolve, RATE_LIMIT_DELAY_MS));
                    }

                    try {
                        const result = await indicatorEngine.checkSymbolTimeframe(
                            symbol,
                            timeframe,
                            rules
                        );

                        // Track cache hits/misses for performance logging
                        if (result.cacheHit) {
                            cacheHitCount++;
                            // Small delay every 20 cache hits to prevent burst when processing many pairs rapidly
                            // This helps distribute load and prevent rate limiting issues
                            if (pairIndex > 0 && pairIndex % 20 === 0) {
                                await new Promise(resolve => setTimeout(resolve, 3));
                            }
                        } else {
                            cacheMissCount++;
                            yahooRequestCount++;
                        }

                        if (result.triggers.length > 0) {
                            Logger.info(`Found ${result.triggers.length} triggers for ${symbol} ${timeframe}`, env);
                            totalTriggers += result.triggers.length;

                            // Send notifications in batches to avoid CPU burst
                            // Reduced to 3 notifications per batch for better CPU distribution
                            const BATCH_SIZE = 3;
                            for (let i = 0; i < result.triggers.length; i += BATCH_SIZE) {
                                const batch = result.triggers.slice(i, i + BATCH_SIZE);
                                const notificationPromises = batch.map(trigger =>
                                    fcmService.sendAlert(trigger).catch(error => {
                                        Logger.error(`Error sending notification for trigger ${trigger.ruleId}:`, error, env);
                                    })
                                );
                                await Promise.all(notificationPromises);
                                
                                // Small delay between batches to prevent CPU burst (reduced from 20ms to 10ms)
                                // 10ms is enough to prevent burst while keeping wall time low
                                if (i + BATCH_SIZE < result.triggers.length) {
                                    await new Promise(resolve => setTimeout(resolve, 10));
                                }
                            }
                        }
                    } catch (error) {
                        Logger.error(`Error checking ${symbol} ${timeframe}:`, error, env);
                        // If we get rate limited (429), add extra delay
                        if (error instanceof Error && error.message.includes('429')) {
                            Logger.warn('Rate limit detected, adding extra delay', env);
                            await new Promise(resolve => setTimeout(resolve, 5000)); // 5 second delay
                        }
                    }
                }

                // Log performance metrics
                const executionTime = Date.now() - startTime;
                const avgTimePerPair = pairsToProcess.length > 0 ? executionTime / pairsToProcess.length : 0;
                Logger.info(`CRON performance: ${pairsToProcess.length} pairs processed (${symbolTimeframePairs.length} total), ${cacheHitCount} cache hits, ${cacheMissCount} cache misses, ${totalTriggers} triggers, ${executionTime}ms total (avg ${Math.round(avgTimePerPair)}ms/pair)`, env);

                // Watchlist Alerts are now handled as regular AlertRule with description "WATCHLIST:"
                // They are automatically processed by IndicatorEngine above, so no separate logic needed

                Logger.info('RSI check completed', env);
            }

            // Periodically cleanup inactive anonymous users (run once per hour, not every minute)
            // Check if current minute is 0 (top of the hour)
            const currentMinute = new Date().getMinutes();
            if (currentMinute === 0) {
                await cleanupInactiveAnonymousUsers(db, env);
            }
        } catch (error) {
            Logger.error('Error in scheduled RSI check:', error, env);
        }
    }
};

/**
 * Clean up alerts for inactive anonymous users (30 days without activity)
 * Only deletes alerts, not devices/sessions
 */
async function cleanupInactiveAnonymousUsers(db: D1Database, env: Env): Promise<void> {
    try {
        const thirtyDaysAgo = Math.floor(Date.now() / 1000) - (30 * 24 * 60 * 60);
        
        // Find anonymous users (user_id starts with 'user_') with no recent activity
        // and who have no devices with recent last_seen
        const inactiveAnonymousUsers = await db.prepare(`
            SELECT DISTINCT ar.user_id 
            FROM alert_rule ar
            WHERE ar.user_id LIKE 'user_%'
            AND NOT EXISTS (
                SELECT 1 FROM device d 
                WHERE d.user_id = ar.user_id 
                AND (d.last_seen > ? OR d.last_seen IS NULL)
            )
        `).bind(thirtyDaysAgo).all();

        const users = inactiveAnonymousUsers.results as { user_id: string }[];
        
        if (users.length === 0) {
            Logger.debug('No inactive anonymous users to clean up', env);
            return;
        }

        Logger.info(`Found ${users.length} inactive anonymous user(s) to clean up`, env);

        let totalAlertsDeleted = 0;
        for (const user of users) {
            try {
                // Delete alert events first (foreign key)
                await db.prepare(`
                    DELETE FROM alert_event 
                    WHERE rule_id IN (SELECT id FROM alert_rule WHERE user_id = ?)
                `).bind(user.user_id).run();

                // Delete alert states (foreign key)
                await db.prepare(`
                    DELETE FROM alert_state 
                    WHERE rule_id IN (SELECT id FROM alert_rule WHERE user_id = ?)
                `).bind(user.user_id).run();

                // Delete alert rules
                const result = await db.prepare(`
                    DELETE FROM alert_rule WHERE user_id = ?
                `).bind(user.user_id).run();

                const deletedCount = result.meta?.changes || 0;
                totalAlertsDeleted += deletedCount;
                
                Logger.debug(`Cleaned up ${deletedCount} alerts for inactive anonymous user: ${user.user_id}`, env);
            } catch (error) {
                Logger.error(`Error cleaning up user ${user.user_id}:`, error, env);
            }
        }

        Logger.info(`Cleanup complete: ${totalAlertsDeleted} alerts deleted from ${users.length} inactive anonymous user(s)`, env);
    } catch (error) {
        Logger.error('Error in cleanupInactiveAnonymousUsers:', error, env);
    }
}

    // User watchlist endpoints
    app.post('/user/watchlist', async (c) => {
        try {
            const { userId, symbols } = await c.req.json();

            if (!userId || !symbols) {
                return c.json({ error: 'Missing userId or symbols' }, 400);
            }

            // Validate symbols array
            if (!Array.isArray(symbols)) {
                return c.json({ error: 'Symbols must be an array' }, 400);
            }

            // Limit watchlist size (max 30 symbols to prevent DoS)
            if (symbols.length > 30) {
                return c.json({ error: 'Watchlist limit exceeded: maximum 30 symbols per user' }, 400);
            }

            // Validate each symbol
            const validSymbols: string[] = [];
            for (const symbol of symbols) {
                if (typeof symbol !== 'string') {
                    continue; // Skip invalid entries
                }
                const symbolUpper = symbol.trim().toUpperCase();
                // Validate symbol (max 20 chars, alphanumeric and common symbols only)
                if (symbolUpper.length > 0 && symbolUpper.length <= 20 && /^[A-Z0-9.\-=]+$/i.test(symbolUpper)) {
                    // Deduplicate (UNIQUE constraint will also prevent duplicates)
                    if (!validSymbols.includes(symbolUpper)) {
                        validSymbols.push(symbolUpper);
                    }
                }
            }

            if (validSymbols.length === 0 && symbols.length > 0) {
                return c.json({ error: 'No valid symbols provided' }, 400);
            }

            const db = c.env?.DB as D1Database;
            await ensureTables(db);

            // Delete existing watchlist for user
            await db.prepare(`
      DELETE FROM user_watchlist WHERE user_id = ?
    `).bind(userId).run();

            // Insert new watchlist (only valid symbols)
            for (const symbol of validSymbols) {
                try {
                    await db.prepare(`
          INSERT INTO user_watchlist (user_id, symbol, created_at)
          VALUES (?, ?, ?)
        `).bind(userId, symbol, Date.now()).run();
                } catch (insertError: any) {
                    // Ignore duplicate errors (UNIQUE constraint)
                    if (!insertError?.message?.includes('UNIQUE')) {
                        Logger.error(`Error inserting symbol ${symbol}:`, insertError, c.env);
                    }
                }
            }

            // Update device activity (user action)
            await updateDeviceActivity(db, userId);

            return c.json({ success: true, count: validSymbols.length });
        } catch (error) {
            Logger.error('Error syncing watchlist:', error, c.env);
            return c.json({ error: 'Failed to sync watchlist' }, 500);
        }
    });

    app.get('/user/watchlist/:userId', async (c) => {
        try {
            const userId = c.req.param('userId');

            const db = c.env?.DB as D1Database;
            await ensureTables(db);

            const result = await db.prepare(`
      SELECT symbol FROM user_watchlist WHERE user_id = ? ORDER BY created_at
    `).bind(userId).all();

            // Update device activity (user action)
            await updateDeviceActivity(db, userId);

            return c.json({ symbols: result.results.map((r: any) => r.symbol) });
        } catch (error) {
            Logger.error('Error fetching watchlist:', error, c.env);
            return c.json({ error: 'Failed to fetch watchlist' }, 500);
        }
    });

    // User preferences endpoints
    app.post('/user/preferences', async (c) => {
        try {
            const { userId, selected_symbol, selected_timeframe, rsi_period, lower_level, upper_level } = await c.req.json();

            if (!userId) {
                return c.json({ error: 'Missing userId' }, 400);
            }

            // Validate symbol if provided
            let validatedSymbol: string | null = null;
            if (selected_symbol !== undefined && selected_symbol !== null) {
                if (typeof selected_symbol !== 'string' || selected_symbol.length > 20) {
                    return c.json({ error: 'Invalid symbol: must be string of max 20 characters' }, 400);
                }
                const symbolUpper = selected_symbol.trim().toUpperCase();
                if (!/^[A-Z0-9.\-=]+$/i.test(symbolUpper)) {
                    return c.json({ error: 'Invalid symbol: contains invalid characters' }, 400);
                }
                validatedSymbol = symbolUpper;
            }

            // Validate timeframe if provided
            if (selected_timeframe !== undefined && selected_timeframe !== null) {
                const validTimeframes = ['1m', '5m', '15m', '1h', '4h', '1d'];
                if (!validTimeframes.includes(selected_timeframe)) {
                    return c.json({ error: `Invalid timeframe: must be one of ${validTimeframes.join(', ')}` }, 400);
                }
            }

            // Validate RSI period if provided
            if (rsi_period !== undefined && rsi_period !== null) {
                if (!Number.isInteger(rsi_period) || rsi_period < 1 || rsi_period > 100) {
                    return c.json({ error: 'Invalid RSI period: must be between 1 and 100' }, 400);
                }
            }

            // Validate levels if provided
            // Allow -100 to 100 to support all indicators (RSI/STOCH: 0-100, WPR: -100-0)
            if (lower_level !== undefined && lower_level !== null) {
                if (typeof lower_level !== 'number' || lower_level < -100 || lower_level > 100 || !isFinite(lower_level)) {
                    return c.json({ error: 'Invalid lower_level: must be number between -100 and 100' }, 400);
                }
            }

            if (upper_level !== undefined && upper_level !== null) {
                if (typeof upper_level !== 'number' || upper_level < -100 || upper_level > 100 || !isFinite(upper_level)) {
                    return c.json({ error: 'Invalid upper_level: must be number between -100 and 100' }, 400);
                }
            }

            const db = c.env?.DB as D1Database;
            await ensureTables(db);

            // Check if preferences exist
            const existing = await db.prepare(`
      SELECT user_id FROM user_preferences WHERE user_id = ?
    `).bind(userId).first();

            if (existing) {
                // Update
                await db.prepare(`
        UPDATE user_preferences SET
          selected_symbol = COALESCE(?, selected_symbol),
          selected_timeframe = COALESCE(?, selected_timeframe),
          rsi_period = COALESCE(?, rsi_period),
          lower_level = COALESCE(?, lower_level),
          upper_level = COALESCE(?, upper_level),
          updated_at = ?
        WHERE user_id = ?
      `            ).bind(
                    validatedSymbol || null,
                    selected_timeframe || null,
                    rsi_period || null,
                    lower_level || null,
                    upper_level || null,
                    Date.now(),
                    userId
                ).run();
            } else {
                // Insert
                await db.prepare(`
        INSERT INTO user_preferences (
          user_id, selected_symbol, selected_timeframe, rsi_period, lower_level, upper_level, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
      `).bind(
                    userId,
                    validatedSymbol || null,
                    selected_timeframe || null,
                    rsi_period || null,
                    lower_level || null,
                    upper_level || null,
                    Date.now()
                ).run();
            }

            // Update device activity (user action)
            await updateDeviceActivity(db, userId);

            return c.json({ success: true });
        } catch (error) {
            Logger.error('Error syncing preferences:', error, c.env);
            return c.json({ error: 'Failed to sync preferences' }, 500);
        }
    });

    app.get('/user/preferences/:userId', async (c) => {
        try {
            const userId = c.req.param('userId');

            const db = c.env?.DB as D1Database;
            await ensureTables(db);

            const result = await db.prepare(`
      SELECT * FROM user_preferences WHERE user_id = ?
    `).bind(userId).first();

            if (!result) {
                return c.json({});
            }

            // Update device activity (user action)
            await updateDeviceActivity(db, userId);

            return c.json({
                selected_symbol: result.selected_symbol,
                selected_timeframe: result.selected_timeframe,
                rsi_period: result.rsi_period,
                lower_level: result.lower_level,
                upper_level: result.upper_level,
            });
        } catch (error) {
            Logger.error('Error fetching preferences:', error, c.env);
            return c.json({ error: 'Failed to fetch preferences' }, 500);
        }
    });

    // Watchlist alert settings endpoints
    app.post('/user/watchlist-alert-settings', async (c) => {
        try {
            const {
                userId,
                indicator,
                enabled,
                timeframe,
                period,
                stochDPeriod,
                mode,
                lowerLevel,
                upperLevel,
                lowerLevelEnabled,
                upperLevelEnabled,
                cooldownSec,
                repeatable,
                onClose
            } = await c.req.json();

            if (!userId || !indicator) {
                return c.json({ error: 'Missing userId or indicator' }, 400);
            }

            // Validate indicator
            const validIndicators = ['rsi', 'stoch', 'wpr'];
            if (!validIndicators.includes(indicator)) {
                return c.json({ error: `Invalid indicator: must be one of ${validIndicators.join(', ')}` }, 400);
            }

            const db = c.env?.DB as D1Database;
            await ensureTables(db);

            // Upsert settings for this user/indicator
            await db.prepare(`
                INSERT INTO watchlist_alert_settings (
                    user_id, indicator, enabled, timeframe, period, stoch_d_period,
                    mode, lower_level, upper_level, lower_level_enabled, upper_level_enabled,
                    cooldown_sec, repeatable, on_close, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(user_id, indicator) DO UPDATE SET
                    enabled = excluded.enabled,
                    timeframe = excluded.timeframe,
                    period = excluded.period,
                    stoch_d_period = excluded.stoch_d_period,
                    mode = excluded.mode,
                    lower_level = excluded.lower_level,
                    upper_level = excluded.upper_level,
                    lower_level_enabled = excluded.lower_level_enabled,
                    upper_level_enabled = excluded.upper_level_enabled,
                    cooldown_sec = excluded.cooldown_sec,
                    repeatable = excluded.repeatable,
                    on_close = excluded.on_close,
                    updated_at = excluded.updated_at
            `).bind(
                userId,
                indicator,
                enabled ? 1 : 0,
                timeframe || '15m',
                period || 14,
                stochDPeriod || null,
                mode || 'cross',
                lowerLevel ?? 30,
                upperLevel ?? 70,
                lowerLevelEnabled !== false ? 1 : 0,
                upperLevelEnabled !== false ? 1 : 0,
                cooldownSec || 600,
                repeatable !== false ? 1 : 0,
                onClose ? 1 : 0,
                Date.now()
            ).run();

            // Update device activity
            await updateDeviceActivity(db, userId);

            return c.json({ success: true });
        } catch (error) {
            Logger.error('Error syncing watchlist alert settings:', error, c.env);
            return c.json({ error: 'Failed to sync watchlist alert settings' }, 500);
        }
    });

    app.get('/user/watchlist-alert-settings/:userId', async (c) => {
        try {
            const userId = c.req.param('userId');

            const db = c.env?.DB as D1Database;
            await ensureTables(db);

            const result = await db.prepare(`
                SELECT * FROM watchlist_alert_settings WHERE user_id = ?
            `).bind(userId).all();

            // Update device activity
            await updateDeviceActivity(db, userId);

            // Group by indicator
            const settings: Record<string, any> = {};
            for (const row of result.results as any[]) {
                settings[row.indicator] = {
                    enabled: row.enabled === 1,
                    timeframe: row.timeframe,
                    period: row.period,
                    stochDPeriod: row.stoch_d_period,
                    mode: row.mode,
                    lowerLevel: row.lower_level,
                    upperLevel: row.upper_level,
                    lowerLevelEnabled: row.lower_level_enabled === 1,
                    upperLevelEnabled: row.upper_level_enabled === 1,
                    cooldownSec: row.cooldown_sec,
                    repeatable: row.repeatable === 1,
                    onClose: row.on_close === 1
                };
            }

            return c.json(settings);
        } catch (error) {
            Logger.error('Error fetching watchlist alert settings:', error, c.env);
            return c.json({ error: 'Failed to fetch watchlist alert settings' }, 500);
        }
    });

    // Admin endpoints
    const adminRoutes = new Hono<{ Bindings: Env }>();
    
    // Apply auth middleware to all admin routes
    adminRoutes.use('*', adminAuthMiddleware);
    
    // Ensure tables exist before handling admin requests
    adminRoutes.use('*', async (c, next) => {
        const db = c.env?.DB as D1Database;
        if (db) {
            await ensureTables(db, c.env);
        }
        await next();
    });
    
    // Stats endpoints
    adminRoutes.get('/stats', getAdminStats);
    adminRoutes.get('/users', getUsers);
    
    // Provider endpoints
    adminRoutes.get('/providers', getProviders);
    adminRoutes.put('/providers', updateProviders);
    
    // Error logging endpoint (public, no auth required)
    app.post('/admin/log-error', logError);
    
    // Error endpoints (require auth)
    adminRoutes.get('/errors', getErrorGroups);
    adminRoutes.get('/errors/:type', getErrorHistory);
    
    // Mount admin routes
    app.route('/admin', adminRoutes);

    export default worker;
