import { Context } from 'hono';
import { Env } from '../index';
import { Logger } from '../logger';

interface ErrorLog {
    id: number;
    type: string;
    message: string;
    errorClass: string;
    timestamp: string;
    userId?: string;
    context?: string;
    symbol?: string;
    timeframe?: string;
    additionalData?: string;
}

interface ErrorGroup {
    type: string;
    count: number;
    lastOccurrence: string;
    sampleMessage: string;
}

/**
 * Log error from client
 */
export async function logError(c: Context<{ Bindings: Env }>) {
    try {
        const errorData = await c.req.json();
        const db = c.env?.DB as D1Database;

        const {
            type,
            message,
            errorClass,
            timestamp,
            userId,
            context,
            symbol,
            timeframe,
            additionalData,
        } = errorData;

        // Validate required fields
        if (!type || !message || !timestamp) {
            return c.json({ error: 'Missing required fields: type, message, timestamp' }, 400);
        }

        // Insert error log
        await db.prepare(`
            INSERT INTO error_log (
                type, message, error_class, timestamp, user_id, context, symbol, timeframe, additional_data
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        `).bind(
            type,
            message,
            errorClass || 'Unknown',
            timestamp,
            userId || null,
            context || null,
            symbol || null,
            timeframe || null,
            additionalData ? JSON.stringify(additionalData) : null
        ).run();

        return c.json({ success: true });
    } catch (error) {
        Logger.error('Error logging error:', error, c.env);
        return c.json({ error: 'Failed to log error' }, 500);
    }
}

/**
 * Get error groups (grouped by type)
 */
export async function getErrorGroups(c: Context<{ Bindings: Env }>) {
    try {
        const db = c.env?.DB as D1Database;
        const hours = c.req.query('hours') ? parseInt(c.req.query('hours')!) : 24;
        const cutoffTime = new Date(Date.now() - hours * 60 * 60 * 1000).toISOString();

        // Get error groups
        const result = await db.prepare(`
            SELECT 
                type,
                COUNT(*) as count,
                MAX(timestamp) as last_occurrence,
                message as sample_message
            FROM error_log
            WHERE timestamp >= ?
            GROUP BY type, message
            ORDER BY count DESC, last_occurrence DESC
            LIMIT 100
        `).bind(cutoffTime).all();

        // Group by type (aggregate counts)
        const groupsMap = new Map<string, ErrorGroup>();
        
        for (const row of result.results as any[]) {
            const type = row.type;
            const existing = groupsMap.get(type);
            
            if (existing) {
                existing.count += row.count;
                if (row.last_occurrence > existing.lastOccurrence) {
                    existing.lastOccurrence = row.last_occurrence;
                    existing.sampleMessage = row.sample_message;
                }
            } else {
                groupsMap.set(type, {
                    type,
                    count: row.count,
                    lastOccurrence: row.last_occurrence,
                    sampleMessage: row.sample_message,
                });
            }
        }

        const groups = Array.from(groupsMap.values()).sort((a, b) => b.count - a.count);

        return c.json({ groups });
    } catch (error) {
        Logger.error('Error fetching error groups:', error, c.env);
        return c.json({ error: 'Failed to fetch error groups' }, 500);
    }
}

/**
 * Get error history for a specific type
 */
export async function getErrorHistory(c: Context<{ Bindings: Env }>) {
    try {
        const type = c.req.param('type');
        const db = c.env?.DB as D1Database;
        const limit = c.req.query('limit') ? parseInt(c.req.query('limit')!) : 100;
        const hours = c.req.query('hours') ? parseInt(c.req.query('hours')!) : 24;
        const cutoffTime = new Date(Date.now() - hours * 60 * 60 * 1000).toISOString();

        const result = await db.prepare(`
            SELECT 
                id,
                type,
                message,
                error_class,
                timestamp,
                user_id,
                context,
                symbol,
                timeframe,
                additional_data
            FROM error_log
            WHERE type = ? AND timestamp >= ?
            ORDER BY timestamp DESC
            LIMIT ?
        `).bind(type, cutoffTime, limit).all();

        const errors = result.results.map((row: any) => ({
            id: row.id,
            type: row.type,
            message: row.message,
            errorClass: row.error_class,
            timestamp: row.timestamp,
            userId: row.user_id,
            context: row.context,
            symbol: row.symbol,
            timeframe: row.timeframe,
            additionalData: row.additional_data ? JSON.parse(row.additional_data) : null,
        }));

        return c.json({ errors });
    } catch (error) {
        Logger.error('Error fetching error history:', error, c.env);
        return c.json({ error: 'Failed to fetch error history' }, 500);
    }
}
