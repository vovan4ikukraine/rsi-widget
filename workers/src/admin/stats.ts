import type { Context } from 'hono';
import type { Env } from '../index';
import { Logger } from '../logger';

interface UserStats {
    total: number;
    active24h: number;
    active7d: number;
    authenticated: number;
    anonymous: number;
}

interface DeviceStats {
    total: number;
    active: number;
    ios: number;
    android: number;
}

interface AlertStats {
    total: number;
    active: number;
    byIndicator: {
        rsi: number;
        stoch: number;
        williams: number;
        [key: string]: number;
    };
    byIndicatorCustom: {
        rsi: number;
        stoch: number;
        williams: number;
        [key: string]: number;
    };
    byIndicatorWatchlist: {
        rsi: number;
        stoch: number;
        williams: number;
        [key: string]: number;
    };
}

interface AdminStats {
    users: UserStats;
    devices: DeviceStats;
    alerts: AlertStats;
    userGrowth?: UserGrowthData; // Optional for backward compatibility
}

interface UserGrowthData {
    dates: string[]; // ISO date strings (YYYY-MM-DD)
    cumulativeCounts: number[]; // Cumulative counts per date (total users)
    dailyCounts: number[]; // Daily counts (new users per day)
}

/**
 * Получить статистику пользователей (считаем по уникальным user_id, не по устройствам)
 */
async function getUserStats(db: D1Database): Promise<UserStats> {
    const now = Date.now();
    const day24hAgo = now - 24 * 60 * 60 * 1000;
    const day7dAgo = now - 7 * 24 * 60 * 60 * 1000;

    // Всего уникальных пользователей = уникальные user_id
    const totalResult = await db.prepare(`
        SELECT COUNT(DISTINCT user_id) as count FROM device
    `).first<{ count: number }>();

    const total = totalResult?.count || 0;

    // Активные за 24 часа (пользователи, у которых хотя бы одно устройство совершало пользовательские действия за последние 24ч)
    // Используем last_seen - время последнего пользовательского действия (не фонового)
    // Если last_seen NULL (старые записи), не считаем активными
    // Handle case where last_seen column might not exist yet (graceful degradation)
    let active24h = 0;
    let active7d = 0;
    try {
        const active24hResult = await db.prepare(`
            SELECT COUNT(DISTINCT user_id) as count 
            FROM device 
            WHERE last_seen IS NOT NULL AND last_seen > ?
        `).bind(Math.floor(day24hAgo / 1000)).first<{ count: number }>();
        active24h = active24hResult?.count || 0;

        // Активные за 7 дней
        const active7dResult = await db.prepare(`
            SELECT COUNT(DISTINCT user_id) as count 
            FROM device 
            WHERE last_seen IS NOT NULL AND last_seen > ?
        `).bind(Math.floor(day7dAgo / 1000)).first<{ count: number }>();
        active7d = active7dResult?.count || 0;
    } catch (error: any) {
        // If last_seen column doesn't exist yet, return 0 for active users
        // This can happen if migration hasn't run yet
        Logger.warn('last_seen column may not exist yet, returning 0 for active users', undefined);
        active24h = 0;
        active7d = 0;
    }
    
    // Упрощенная логика: считаем все как пользователей, без разделения на анонимных/аутентифицированных
    // (так как одно устройство может быть и анонимным, и потом залогиненным)
    return {
        total,
        active24h,
        active7d,
        authenticated: 0, // Не считаем, так как нет надежного способа определить
        anonymous: 0, // Не считаем
    };
}

/**
 * Получить статистику устройств
 */
async function getDeviceStats(db: D1Database): Promise<DeviceStats> {
    const totalResult = await db.prepare(`
        SELECT COUNT(*) as count FROM device
    `).first<{ count: number }>();

    // Для простоты считаем все устройства активными (так как нет поля is_active)
    // В будущем можно добавить колонку last_seen в таблицу device
    const activeCount = totalResult?.count || 0;

    const iosResult = await db.prepare(`
        SELECT COUNT(*) as count FROM device WHERE platform = 'ios'
    `).first<{ count: number }>();

    const androidResult = await db.prepare(`
        SELECT COUNT(*) as count FROM device WHERE platform = 'android'
    `).first<{ count: number }>();

    return {
        total: activeCount,
        active: activeCount,
        ios: iosResult?.count || 0,
        android: androidResult?.count || 0,
    };
}

/**
 * Получить статистику алертов
 */
async function getAlertStats(db: D1Database): Promise<AlertStats> {
    const totalResult = await db.prepare(`
        SELECT COUNT(*) as count FROM alert_rule
    `).first<{ count: number }>();

    const activeResult = await db.prepare(`
        SELECT COUNT(*) as count FROM alert_rule WHERE active = 1
    `).first<{ count: number }>();

    // Статистика по индикаторам (общая)
    const indicatorStats = await db.prepare(`
        SELECT indicator, COUNT(*) as count 
        FROM alert_rule 
        WHERE active = 1 
        GROUP BY indicator
    `).all<{ indicator: string; count: number }>();

    const byIndicator: { rsi: number; stoch: number; williams: number; [key: string]: number } = {
        rsi: 0,
        stoch: 0,
        williams: 0,
    };

    for (const row of indicatorStats.results || []) {
        const indicator = row.indicator?.toLowerCase() || 'rsi';
        const normalizedIndicator = indicator === 'wpr' ? 'williams' : indicator;
        byIndicator[normalizedIndicator] = (byIndicator[normalizedIndicator] || 0) + (row.count || 0);
    }

    // Статистика по индикаторам для кастомных алертов (без WATCHLIST)
    const customIndicatorStats = await db.prepare(`
        SELECT indicator, COUNT(*) as count 
        FROM alert_rule 
        WHERE active = 1 
        AND (description IS NULL OR description NOT LIKE 'WATCHLIST:%')
        GROUP BY indicator
    `).all<{ indicator: string; count: number }>();

    const byIndicatorCustom: { rsi: number; stoch: number; williams: number; [key: string]: number } = {
        rsi: 0,
        stoch: 0,
        williams: 0,
    };

    for (const row of customIndicatorStats.results || []) {
        const indicator = row.indicator?.toLowerCase() || 'rsi';
        const normalizedIndicator = indicator === 'wpr' ? 'williams' : indicator;
        byIndicatorCustom[normalizedIndicator] = (byIndicatorCustom[normalizedIndicator] || 0) + (row.count || 0);
    }

    // Статистика по индикаторам для watchlist алертов (с WATCHLIST)
    const watchlistIndicatorStats = await db.prepare(`
        SELECT indicator, COUNT(*) as count 
        FROM alert_rule 
        WHERE active = 1 
        AND description LIKE 'WATCHLIST:%'
        GROUP BY indicator
    `).all<{ indicator: string; count: number }>();

    const byIndicatorWatchlist: { rsi: number; stoch: number; williams: number; [key: string]: number } = {
        rsi: 0,
        stoch: 0,
        williams: 0,
    };

    for (const row of watchlistIndicatorStats.results || []) {
        const indicator = row.indicator?.toLowerCase() || 'rsi';
        const normalizedIndicator = indicator === 'wpr' ? 'williams' : indicator;
        byIndicatorWatchlist[normalizedIndicator] = (byIndicatorWatchlist[normalizedIndicator] || 0) + (row.count || 0);
    }

    return {
        total: totalResult?.count || 0,
        active: activeResult?.count || 0,
        byIndicator,
        byIndicatorCustom,
        byIndicatorWatchlist,
    };
}

/**
 * Получить данные роста пользователей по датам (считаем уникальных user_id, а не устройства)
 */
async function getUserGrowth(db: D1Database): Promise<UserGrowthData> {
    try {
        // Получаем уникальных пользователей (user_id) с датами первого устройства
        // Для каждого user_id берем MIN(created_at) - дату регистрации первого устройства
        // created_at хранится в миллисекундах (Date.now())
        // Делим на 1000 чтобы получить секунды для datetime()
        // strftime('%Y-%m-%d', ...) extracts just the date part (YYYY-MM-DD)
        const result = await db.prepare(`
            SELECT 
                strftime('%Y-%m-%d', datetime(CAST(MIN(created_at) AS REAL) / 1000, 'unixepoch')) as date,
                COUNT(DISTINCT user_id) as count
            FROM device
            WHERE created_at IS NOT NULL
            GROUP BY user_id
        `).all<{ date: string; count: number }>();

        // Теперь группируем по дате, чтобы получить количество новых пользователей за каждый день
        const dailyDataMap = new Map<string, number>();
        
        for (const row of result.results || []) {
            if (row.date && row.date !== '') {
                const currentCount = dailyDataMap.get(row.date) || 0;
                dailyDataMap.set(row.date, currentCount + 1); // Каждый user_id считается как 1 новый пользователь в день
            }
        }

        // Сортируем по дате и строим кумулятивные значения
        const sortedDates = Array.from(dailyDataMap.keys()).sort();
        const dates: string[] = [];
        const cumulativeCounts: number[] = [];
        const dailyCounts: number[] = [];
        let cumulativeCount = 0;

        for (const date of sortedDates) {
            dates.push(date);
            const dailyCount = dailyDataMap.get(date) || 0;
            dailyCounts.push(dailyCount);
            cumulativeCount += dailyCount;
            cumulativeCounts.push(cumulativeCount);
        }

        return {
            dates,
            cumulativeCounts,
            dailyCounts,
        };
    } catch (error: any) {
        Logger.error('Error fetching user growth data:', error, undefined);
        // Return empty data instead of throwing to prevent breaking the whole stats endpoint
        return {
            dates: [],
            cumulativeCounts: [],
            dailyCounts: [],
        };
    }
}

/**
 * Handler для получения общей статистики
 */
export async function getAdminStats(c: Context<{ Bindings: Env }>) {
    try {
        const db = c.env?.DB as D1Database;
        
        // Ensure tables exist (including migrations like last_seen column)
        // Import ensureTables from index.ts - but we can't import it directly
        // So we'll handle potential missing column gracefully in queries
        
        const [users, devices, alerts, userGrowth] = await Promise.all([
            getUserStats(db),
            getDeviceStats(db),
            getAlertStats(db),
            getUserGrowth(db),
        ]);

        const stats: AdminStats = {
            users,
            devices,
            alerts,
            userGrowth,
        };

        return c.json(stats);
    } catch (error) {
        Logger.error('Error fetching admin stats:', error, c.env);
        return c.json({ error: 'Failed to fetch stats' }, 500);
    }
}

/**
 * Handler для получения списка пользователей
 */
export async function getUsers(c: Context<{ Bindings: Env }>) {
    try {
        const db = c.env?.DB as D1Database;
        const limit = parseInt(c.req.query('limit') || '50');
        const offset = parseInt(c.req.query('offset') || '0');

        const users = await db.prepare(`
            SELECT DISTINCT 
                d.user_id,
                COUNT(DISTINCT d.id) as device_count,
                MAX(d.created_at) as last_seen,
                MAX(d.created_at) as created_at
            FROM device d
            GROUP BY d.user_id
            ORDER BY last_seen DESC
            LIMIT ? OFFSET ?
        `).bind(limit, offset).all();

        const totalResult = await db.prepare(`
            SELECT COUNT(DISTINCT user_id) as count FROM device
        `).first<{ count: number }>();

        return c.json({
            users: users.results || [],
            total: totalResult?.count || 0,
            limit,
            offset,
        });
    } catch (error) {
        Logger.error('Error fetching users:', error, c.env);
        return c.json({ error: 'Failed to fetch users' }, 500);
    }
}

