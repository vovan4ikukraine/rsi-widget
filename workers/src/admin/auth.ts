import type { Context } from 'hono';
import type { Next } from 'hono';
import type { Env } from '../index';
import { Logger } from '../logger';

/**
 * Middleware для проверки админ API ключа
 */
export async function adminAuthMiddleware(c: Context<{ Bindings: Env }>, next: Next): Promise<Response | void> {
    const apiKey = c.req.header('X-Admin-API-Key');
    const envApiKey = c.env?.ADMIN_API_KEY;

    if (!envApiKey) {
        Logger.warn('ADMIN_API_KEY not configured in environment', c.env);
        return c.json({ error: 'Admin API not configured' }, 500);
    }

    if (!apiKey || apiKey !== envApiKey) {
        Logger.warn('Invalid admin API key attempt', c.env);
        return c.json({ error: 'Unauthorized' }, 401);
    }

    return await next();
}







