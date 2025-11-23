import { Hono } from 'hono';
import { cors } from 'hono/cors';
import { IndicatorEngine } from './rsi-engine';
import { FcmService } from './fcm-service';
import { YahooService } from './yahoo-service';
import { Logger } from './logger';

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
}

// CORS middleware
app.use('*', cors({
    origin: '*',
    allowHeaders: ['Content-Type', 'Authorization'],
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

// Proxy for Yahoo Finance
app.get('/yf/candles', async (c) => {
    try {
        const { symbol, tf, since, limit } = c.req.query();

        if (!symbol || !tf) {
            return c.json({ error: 'Missing symbol or timeframe' }, 400);
        }

        const yahooService = new YahooService(c.env?.YAHOO_ENDPOINT as string || '');
        const kv = c.env?.KV as KVNamespace;

        // Try to get from cache first
        if (kv) {
            const cachedCandles = await yahooService.getCachedCandles(symbol, tf, kv);
            if (cachedCandles) {
                Logger.cacheHit(symbol, tf, cachedCandles.length, c.env);

                // Apply limit if specified (for cached data)
                let result = cachedCandles;
                if (limit) {
                    const limitNum = parseInt(limit);
                    result = cachedCandles.slice(-limitNum);
                }

                // Add debug info if requested
                const debug = c.req.query('debug') === 'true';
                if (debug) {
                    const timestamp = new Date().toISOString();
                    return c.json({
                        data: result,
                        meta: {
                            source: 'cache',
                            symbol: symbol,
                            timeframe: tf,
                            count: result.length,
                            timestamp: timestamp,
                        }
                    });
                }

                // Set header to indicate cache hit
                c.header('X-Data-Source', 'cache');
                return c.json(result);
            }
        }

        // Cache miss or no KV - fetch from Yahoo
        Logger.cacheMiss(symbol, tf, c.env);

        const candles = await yahooService.getCandles(symbol, tf, {
            since: since ? parseInt(since) : undefined,
            limit: limit ? parseInt(limit) : 1000,
        });

        // Save to cache for future requests
        if (kv && candles.length > 0) {
            await yahooService.setCachedCandles(symbol, tf, candles, kv);
            Logger.cacheSave(symbol, tf, candles.length, c.env);
        }

        // Add debug info if requested
        const debug = c.req.query('debug') === 'true';
        if (debug) {
            const timestamp = new Date().toISOString();
            return c.json({
                data: candles,
                meta: {
                    source: 'yahoo',
                    symbol: symbol,
                    timeframe: tf,
                    count: candles.length,
                    timestamp: timestamp,
                }
            });
        }

        // Set header to indicate Yahoo fetch
        c.header('X-Data-Source', 'yahoo');
        return c.json(candles);
    } catch (error) {
        Logger.error('Error fetching candles:', error, c.env);
        return c.json({ error: 'Failed to fetch candles' }, 500);
    }
});

// Get current price
app.get('/yf/quote', async (c) => {
    try {
        const { symbol } = c.req.query();

        if (!symbol) {
            return c.json({ error: 'Missing symbol' }, 400);
        }

        const yahooService = new YahooService(c.env?.YAHOO_ENDPOINT as string || '');
        const quote = await yahooService.getQuote(symbol);

        return c.json(quote);
    } catch (error) {
        Logger.error('Error fetching quote:', error, c.env);
        return c.json({ error: 'Failed to fetch quote' }, 500);
    }
});

// Symbol information
app.get('/yf/info', async (c) => {
    try {
        const { symbol } = c.req.query();

        if (!symbol) {
            return c.json({ error: 'Missing symbol' }, 400);
        }

        const yahooService = new YahooService(c.env?.YAHOO_ENDPOINT as string || '');
        const info = await yahooService.getSymbolInfo(symbol);

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

        const result = await db.prepare(`
      INSERT OR REPLACE INTO device (id, user_id, fcm_token, platform, created_at)
      VALUES (?, ?, ?, ?, ?)
    `).bind(deviceId, userId, fcmToken, platform, Date.now()).run();

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
            cooldownSec
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
        const validIndicators = ['rsi', 'stoch', 'macd', 'bollinger', 'williams'];
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

        // Validate levels (array of numbers between 0-100)
        if (!Array.isArray(levels) || levels.length === 0 || levels.length > 10) {
            return c.json({ error: 'Invalid levels: must be array of 1-10 numbers' }, 400);
        }
        for (const level of levels) {
            if (typeof level !== 'number' || level < 0 || level > 100 || !isFinite(level)) {
                return c.json({ error: 'Invalid level: must be number between 0 and 100' }, 400);
            }
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

        const db = c.env?.DB as D1Database;
        await ensureTables(db);

        // Check alert limit per user (max 100 alerts to prevent DoS)
        const countResult = await db.prepare(`
            SELECT COUNT(*) as count FROM alert_rule WHERE user_id = ? AND active = 1
        `).bind(userId).first<{ count: number }>();
        const alertCount = countResult?.count || 0;
        if (alertCount >= 100) {
            return c.json({ error: 'Alert limit reached: maximum 100 active alerts per user' }, 400);
        }

        const result = await db.prepare(`
      INSERT INTO alert_rule (
        user_id, symbol, timeframe, indicator, period, indicator_params, rsi_period, levels, mode, 
        cooldown_sec, active, created_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?)
    `).bind(
            userId, symbol.toUpperCase(), timeframe, alertIndicator, alertPeriod,
            indicatorParamsJson, alertPeriod, // rsi_period for backward compatibility
            JSON.stringify(levels), alertMode,
            cooldown, Date.now()
        ).run();

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
            SELECT user_id FROM alert_rule WHERE id = ?
        `).bind(ruleId).first<{ user_id: string }>();

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
            const validIndicators = ['rsi', 'stoch', 'macd', 'bollinger', 'williams'];
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
            if (!Array.isArray(updates.levels) || updates.levels.length === 0 || updates.levels.length > 10) {
                return c.json({ error: 'Invalid levels: must be array of 1-10 numbers' }, 400);
            }
            for (const level of updates.levels) {
                if (typeof level !== 'number' || level < 0 || level > 100 || !isFinite(level)) {
                    return c.json({ error: 'Invalid level: must be number between 0 and 100' }, 400);
                }
            }
            updates.levels = JSON.stringify(updates.levels);
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

            // Check FCM configuration only if we have active rules
            if (!env.FCM_SERVICE_ACCOUNT_JSON || env.FCM_SERVICE_ACCOUNT_JSON.trim() === '') {
                Logger.error('FCM_SERVICE_ACCOUNT_JSON is not set! Please set it via: wrangler secret put FCM_SERVICE_ACCOUNT_JSON', undefined, env);
                Logger.error('Paste the entire Service Account JSON file content', undefined, env);
                return;
            }

            if (!env.FCM_PROJECT_ID || env.FCM_PROJECT_ID.trim() === '') {
                Logger.error('FCM_PROJECT_ID is not set! Please set it in wrangler.toml [vars]', undefined, env);
                return;
            }

            const indicatorEngine = new IndicatorEngine(db, new YahooService(env.YAHOO_ENDPOINT), env.KV);
            const fcmService = new FcmService(env.FCM_SERVICE_ACCOUNT_JSON, env.FCM_PROJECT_ID, env.KV, env.DB);

            // Get active rules (we already know there are some)
            const rules = await indicatorEngine.getActiveRules();

            // Group by symbols and timeframes
            const groupedRules = indicatorEngine.groupRulesBySymbolTimeframe(rules);
            const symbolTimeframePairs = Object.entries(groupedRules);

            // Rate limiting: max 3 requests per second to Yahoo Finance to avoid hitting limits
            // This spreads requests over time (e.g., 300 pairs = ~100 seconds max)
            const RATE_LIMIT_DELAY_MS = 350; // ~3 requests per second
            let requestCount = 0;

            // Check each symbol/timeframe with rate limiting
            for (const [key, rules] of symbolTimeframePairs) {
                const [symbol, timeframe] = key.split('|');

                // Add delay between requests to respect rate limits
                if (requestCount > 0) {
                    await new Promise(resolve => setTimeout(resolve, RATE_LIMIT_DELAY_MS));
                }

                try {
                    const triggers = await indicatorEngine.checkSymbolTimeframe(
                        symbol,
                        timeframe,
                        rules
                    );

                    // Only increment if we actually made a request (cache miss)
                    // This is approximate - actual rate limiting happens in checkSymbolTimeframe
                    requestCount++;

                    if (triggers.length > 0) {
                        Logger.info(`Found ${triggers.length} triggers for ${symbol} ${timeframe}`, env);

                        // Send notifications
                        for (const trigger of triggers) {
                            await fcmService.sendAlert(trigger);
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

            Logger.info('RSI check completed', env);
        } catch (error) {
            Logger.error('Error in scheduled RSI check:', error, env);
        }
    }
};

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

        // Limit watchlist size (max 50 symbols to prevent DoS)
        if (symbols.length > 50) {
            return c.json({ error: 'Watchlist limit exceeded: maximum 50 symbols per user' }, 400);
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
        if (lower_level !== undefined && lower_level !== null) {
            if (typeof lower_level !== 'number' || lower_level < 0 || lower_level > 100 || !isFinite(lower_level)) {
                return c.json({ error: 'Invalid lower_level: must be number between 0 and 100' }, 400);
            }
        }

        if (upper_level !== undefined && upper_level !== null) {
            if (typeof upper_level !== 'number' || upper_level < 0 || upper_level > 100 || !isFinite(upper_level)) {
                return c.json({ error: 'Invalid upper_level: must be number between 0 and 100' }, 400);
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

export default worker;
