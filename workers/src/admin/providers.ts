import { Context } from 'hono';
import { Env } from '../index';
import { Logger } from '../logger';

interface ProviderConfig {
    primary: string;
    fallback: string | null;
    status: 'online' | 'offline' | 'unknown';
}

interface ProvidersConfig {
    stocks: ProviderConfig;
    crypto: ProviderConfig;
    forex: ProviderConfig;
}

/**
 * Получить текущую конфигурацию провайдеров
 * Пока возвращает заглушку - в будущем можно читать из БД или env
 */
export async function getProviders(c: Context<{ Bindings: Env }>) {
    try {
        // TODO: В будущем читать из БД или env переменных
        const config: ProvidersConfig = {
            stocks: {
                primary: 'YF_PROTO',
                fallback: null,
                status: 'online',
            },
            crypto: {
                primary: 'YF_PROTO',
                fallback: null,
                status: 'online',
            },
            forex: {
                primary: 'YF_PROTO',
                fallback: null,
                status: 'online',
            },
        };

        return c.json(config);
    } catch (error) {
        Logger.error('Error fetching providers:', error, c.env);
        return c.json({ error: 'Failed to fetch providers' }, 500);
    }
}

/**
 * Обновить конфигурацию провайдеров
 * Пока заглушка - ничего не делает, только валидирует и возвращает успех
 */
export async function updateProviders(c: Context<{ Bindings: Env }>) {
    try {
        const body = await c.req.json<Partial<ProvidersConfig>>();

        // Валидация
        const validProviders = ['YF_PROTO', 'BINANCE', 'KRAKEN', 'TWELVE', 'ALPHA_VANTAGE'];
        const validTypes = ['stocks', 'crypto', 'forex'];

        for (const [type, config] of Object.entries(body)) {
            if (!validTypes.includes(type)) {
                return c.json({ error: `Invalid provider type: ${type}` }, 400);
            }

            if (config && typeof config === 'object') {
                if ('primary' in config && !validProviders.includes(config.primary)) {
                    return c.json({ error: `Invalid primary provider: ${config.primary}` }, 400);
                }
                if ('fallback' in config && config.fallback && !validProviders.includes(config.fallback)) {
                    return c.json({ error: `Invalid fallback provider: ${config.fallback}` }, 400);
                }
            }
        }

        // TODO: В будущем сохранять в БД или env переменные
        // Пока просто возвращаем успех
        Logger.info('Provider config update requested (stub):', body, c.env);

        return c.json({
            success: true,
            message: 'Provider configuration update is not yet implemented. This is a stub endpoint.',
            config: body,
        });
    } catch (error) {
        Logger.error('Error updating providers:', error, c.env);
        return c.json({ error: 'Failed to update providers' }, 500);
    }
}






