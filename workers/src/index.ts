import { Hono } from 'hono';
import { cors } from 'hono/cors';
import { RsiEngine } from './rsi-engine';
import { FcmService } from './fcm-service';
import { YahooService } from './yahoo-service';

export interface Env {
    KV: KVNamespace;
    DB: D1Database;
    FCM_SERVER_KEY: string;
    YAHOO_ENDPOINT: string;
    FCM_ENDPOINT: string;
    [key: string]: any;
}

const app = new Hono<{ Bindings: Env }>();

// CORS middleware
app.use('*', cors({
    origin: '*',
    allowHeaders: ['Content-Type', 'Authorization'],
    allowMethods: ['GET', 'POST', 'PUT', 'DELETE', 'OPTIONS'],
}));


// Proxy for Yahoo Finance
app.get('/yf/candles', async (c) => {
    try {
        const { symbol, tf, since, limit } = c.req.query();

        if (!symbol || !tf) {
            return c.json({ error: 'Missing symbol or timeframe' }, 400);
        }

        const yahooService = new YahooService(c.env?.YAHOO_ENDPOINT as string || '');
        const candles = await yahooService.getCandles(symbol, tf, {
            since: since ? parseInt(since) : undefined,
            limit: limit ? parseInt(limit) : 1000,
        });

        return c.json(candles);
    } catch (error) {
        console.error('Error fetching candles:', error);
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
        console.error('Error fetching quote:', error);
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
        console.error('Error fetching symbol info:', error);
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
        console.error('Error searching symbols:', error);
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

        const result = await (c.env?.DB as D1Database).prepare(`
      INSERT OR REPLACE INTO device (id, user_id, fcm_token, platform, created_at)
      VALUES (?, ?, ?, ?, ?)
    `).bind(deviceId, userId, fcmToken, platform, Date.now()).run();

        return c.json({ success: true, id: result.meta.last_row_id });
    } catch (error) {
        console.error('Error registering device:', error);
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
            rsiPeriod,
            levels,
            mode,
            hysteresis,
            cooldownSec
        } = await c.req.json();

        if (!userId || !symbol || !timeframe || !levels) {
            return c.json({ error: 'Missing required fields' }, 400);
        }

        const result = await (c.env?.DB as D1Database).prepare(`
      INSERT INTO alert_rule (
        user_id, symbol, timeframe, rsi_period, levels, mode, 
        hysteresis, cooldown_sec, active, created_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, ?)
    `).bind(
            userId, symbol, timeframe, rsiPeriod || 14,
            JSON.stringify(levels), mode || 'cross',
            hysteresis || 0.5, cooldownSec || 600, Date.now()
        ).run();

        return c.json({ success: true, id: result.meta.last_row_id });
    } catch (error) {
        console.error('Error creating alert rule:', error);
        return c.json({ error: 'Failed to create alert rule' }, 500);
    }
});

// Get user rules
app.get('/alerts/:userId', async (c) => {
    try {
        const userId = c.req.param('userId');

        const result = await (c.env?.DB as D1Database).prepare(`
      SELECT * FROM alert_rule WHERE user_id = ? AND active = 1
    `).bind(userId).all();

        return c.json({ rules: result.results });
    } catch (error) {
        console.error('Error fetching alert rules:', error);
        return c.json({ error: 'Failed to fetch alert rules' }, 500);
    }
});

// Update rule
app.put('/alerts/:ruleId', async (c) => {
    try {
        const ruleId = c.req.param('ruleId');
        const updates = await c.req.json();

        const fields = Object.keys(updates)
            .filter(key => key !== 'id')
            .map(key => `${key} = ?`)
            .join(', ');

        const values = Object.values(updates);
        values.push(ruleId);

        await (c.env?.DB as D1Database).prepare(`
      UPDATE alert_rule SET ${fields} WHERE id = ?
    `).bind(...values).run();

        return c.json({ success: true });
    } catch (error) {
        console.error('Error updating alert rule:', error);
        return c.json({ error: 'Failed to update alert rule' }, 500);
    }
});

// Delete rule
app.delete('/alerts/:ruleId', async (c) => {
    try {
        const ruleId = c.req.param('ruleId');

        await (c.env?.DB as D1Database).prepare(`
      UPDATE alert_rule SET active = 0 WHERE id = ?
    `).bind(ruleId).run();

        return c.json({ success: true });
    } catch (error) {
        console.error('Error deleting alert rule:', error);
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

        // Fixed: RsiEngine expects only 2 arguments (DB, YahooService)
        const rsiEngine = new RsiEngine(c.env?.DB as D1Database, new YahooService(c.env?.YAHOO_ENDPOINT as string || ''));
        const results = await rsiEngine.checkAlerts(symbols, timeframes);

        return c.json({ results });
    } catch (error) {
        console.error('Error checking alerts:', error);
        return c.json({ error: 'Failed to check alerts' }, 500);
    }
});

// Cron job for checking alerts
const worker: ExportedHandler<Env> = {
    fetch: app.fetch,
    scheduled: async (_controller: ScheduledController, env: Env, _ctx: ExecutionContext) => {
        console.log('Running scheduled RSI check...');

        try {
            const rsiEngine = new RsiEngine(env.DB, new YahooService(env.YAHOO_ENDPOINT));
            const fcmService = new FcmService(env.FCM_SERVER_KEY, env.FCM_ENDPOINT, env.DB);

            // Get active rules
            const rules = await rsiEngine.getActiveRules();

            if (rules.length === 0) {
                console.log('No active rules found');
                return;
            }

            // Group by symbols and timeframes
            const groupedRules = rsiEngine.groupRulesBySymbolTimeframe(rules);

            // Check each symbol/timeframe
            for (const [key, rules] of Object.entries(groupedRules)) {
                const [symbol, timeframe] = key.split('|');

                try {
                    const triggers = await rsiEngine.checkSymbolTimeframe(
                        symbol,
                        timeframe,
                        rules
                    );

                    if (triggers.length > 0) {
                        console.log(`Found ${triggers.length} triggers for ${symbol} ${timeframe}`);

                        // Send notifications
                        for (const trigger of triggers) {
                            await fcmService.sendAlert(trigger);
                        }
                    }
                } catch (error) {
                    console.error(`Error checking ${symbol} ${timeframe}:`, error);
                }
            }

            console.log('RSI check completed');
        } catch (error) {
            console.error('Error in scheduled RSI check:', error);
        }
    }
};

export default worker;
