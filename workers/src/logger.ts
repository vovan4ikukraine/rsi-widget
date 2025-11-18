/**
 * Logger utility with log levels
 * In production, only logs errors and warnings
 * In development, logs everything
 */
export class Logger {
    private static isProduction(env: any): boolean {
        return env?.ENVIRONMENT === 'production';
    }

    private static shouldLog(level: 'debug' | 'info' | 'warn' | 'error', env: any): boolean {
        const isProd = this.isProduction(env);

        // In production: only log warnings and errors
        // In development: log everything
        if (isProd) {
            return level === 'warn' || level === 'error';
        }
        return true;
    }

    static debug(message: string, env?: any): void {
        if (this.shouldLog('debug', env)) {
            console.log(`[DEBUG] ${message}`);
        }
    }

    static info(message: string, env?: any): void {
        if (this.shouldLog('info', env)) {
            console.log(`[INFO] ${message}`);
        }
    }

    static warn(message: string, env?: any): void {
        if (this.shouldLog('warn', env)) {
            console.warn(`[WARN] ${message}`);
        }
    }

    static error(message: string, error?: any, env?: any): void {
        if (this.shouldLog('error', env)) {
            console.error(`[ERROR] ${message}`, error || '');
        }
    }

    // Special method for cache operations (important for monitoring)
    static cacheHit(symbol: string, timeframe: string, count: number, env?: any): void {
        // Cache hits are important even in production for monitoring
        if (!this.isProduction(env)) {
            const timestamp = new Date().toISOString();
            console.log(`[${timestamp}] ✅ CACHE HIT for ${symbol} ${timeframe} (${count} candles)`);
        }
    }

    static cacheMiss(symbol: string, timeframe: string, env?: any): void {
        // Cache misses are important even in production
        if (!this.isProduction(env)) {
            const timestamp = new Date().toISOString();
            console.log(`[${timestamp}] ❌ CACHE MISS for ${symbol} ${timeframe}, fetching from Yahoo Finance...`);
        }
    }

    static cacheSave(symbol: string, timeframe: string, count: number, env?: any): void {
        // Cache saves are less critical, only log in dev
        if (!this.isProduction(env)) {
            const timestamp = new Date().toISOString();
            console.log(`[${timestamp}] 💾 Cached ${count} candles for ${symbol} ${timeframe}`);
        }
    }
}

