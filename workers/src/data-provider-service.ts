import { YahooService, type CandleData, type QuoteData, type SymbolInfo } from './yahoo-service';
import { BinanceService } from './binance-service';
import { SymbolMapper } from './symbol-mapper';

// D1Database type (from Cloudflare Workers)
interface D1Database {
    prepare(query: string): D1PreparedStatement;
}

interface D1PreparedStatement {
    bind(...values: any[]): D1PreparedStatement;
    first<T = any>(): Promise<T | null>;
    run(): Promise<D1Result>;
}

interface D1Result {
    success: boolean;
    meta: {
        changes: number;
        last_row_id: number;
        duration: number;
    };
}

export type DataProvider = 'yahoo' | 'binance';

/**
 * DataProviderService: Facade for selecting data provider
 * 
 * Logic:
 * - TEMPORARILY: Using only Yahoo (Binance disabled until proxy is set up)
 * - FUTURE: For crypto: Try Binance first, fallback to Yahoo on error
 * - For non-crypto: Always use Yahoo
 * 
 * Cache key: Always uses Yahoo format (BTC-USD) for consistency
 */
export class DataProviderService {
    // Temporary flag to disable Binance until proxy is ready
    private static readonly USE_BINANCE = false;
    constructor(
        private yahooService: YahooService,
        private binanceService: BinanceService,
        private db: D1Database
    ) { }

    /**
     * Get candles with automatic provider selection
     * 
     * @param symbol Yahoo format symbol (e.g., BTC-USD)
     * @param timeframe Timeframe
     * @param options Options including since and limit
     * @returns Candles data and provider used
     */
    async getCandles(
        symbol: string,
        timeframe: string,
        options: {
            since?: number;
            limit?: number;
        } = {}
    ): Promise<{ candles: CandleData[]; provider: DataProvider }> {
        // Check cache first (always uses Yahoo format as key)
        const cached = await this.getCachedCandles(symbol, timeframe);
        if (cached) {
            return { candles: cached.candles, provider: cached.provider };
        }

        // Determine if crypto
        const isCrypto = SymbolMapper.isCrypto(symbol);

        // TEMPORARILY DISABLED: Binance until proxy is set up
        // Uncomment this block when proxy is ready and set USE_BINANCE = true
        if (isCrypto && DataProviderService.USE_BINANCE) {
            // Try Binance first for crypto
            const binanceSymbol = SymbolMapper.yahooToBinance(symbol);
            if (binanceSymbol) {
                try {
                    console.log(`DataProvider: Trying Binance for ${symbol} (${binanceSymbol})`);
                    const candles = await this.binanceService.getCandles(binanceSymbol, timeframe, options);
                    
                    // Cache with provider info
                    await this.setCachedCandles(symbol, timeframe, candles, 'binance');
                    
                    return { candles, provider: 'binance' };
                } catch (error) {
                    console.warn(`DataProvider: Binance failed for ${symbol}, falling back to Yahoo:`, error);
                    // Fall through to Yahoo fallback
                }
            }
        }

        // Use Yahoo (for all symbols while Binance is disabled)
        try {
            console.log(`DataProvider: Using Yahoo for ${symbol}`);
            const candles = await this.yahooService.getCandles(symbol, timeframe, options);
            
            // Cache with provider info
            await this.setCachedCandles(symbol, timeframe, candles, 'yahoo');
            
            return { candles, provider: 'yahoo' };
        } catch (error) {
            console.error(`DataProvider: Yahoo failed for ${symbol}:`, error);
            throw error;
        }
    }

    /**
     * Get quote with automatic provider selection
     */
    async getQuote(symbol: string): Promise<{ quote: QuoteData; provider: DataProvider }> {
        const isCrypto = SymbolMapper.isCrypto(symbol);

        // TEMPORARILY DISABLED: Binance until proxy is set up
        if (isCrypto && DataProviderService.USE_BINANCE) {
            const binanceSymbol = SymbolMapper.yahooToBinance(symbol);
            if (binanceSymbol) {
                try {
                    const quote = await this.binanceService.getQuote(binanceSymbol);
                    // Convert symbol back to Yahoo format for consistency
                    quote.symbol = symbol;
                    return { quote, provider: 'binance' };
                } catch (error) {
                    console.warn(`DataProvider: Binance quote failed for ${symbol}, falling back to Yahoo:`, error);
                }
            }
        }

        // Use Yahoo
        const quote = await this.yahooService.getQuote(symbol);
        return { quote, provider: 'yahoo' };
    }

    /**
     * Get symbol info with automatic provider selection
     */
    async getSymbolInfo(symbol: string): Promise<{ info: SymbolInfo; provider: DataProvider }> {
        const isCrypto = SymbolMapper.isCrypto(symbol);

        // TEMPORARILY DISABLED: Binance until proxy is set up
        if (isCrypto && DataProviderService.USE_BINANCE) {
            const binanceSymbol = SymbolMapper.yahooToBinance(symbol);
            if (binanceSymbol) {
                try {
                    const info = await this.binanceService.getSymbolInfo(binanceSymbol);
                    // Convert symbol back to Yahoo format for consistency
                    info.symbol = symbol;
                    return { info, provider: 'binance' };
                } catch (error) {
                    console.warn(`DataProvider: Binance info failed for ${symbol}, falling back to Yahoo:`, error);
                }
            }
        }

        // Use Yahoo
        const info = await this.yahooService.getSymbolInfo(symbol);
        return { info, provider: 'yahoo' };
    }

    /**
     * Get cached candles with provider info
     */
    async getCachedCandles(
        symbol: string,
        timeframe: string
    ): Promise<{ candles: CandleData[]; provider: DataProvider } | null> {
        try {
            const now = Date.now();
            const maxCacheAge = 60 * 1000; // 60 seconds

            const result = await this.db.prepare(`
                SELECT candles_json, cached_at, provider
                FROM candles_cache 
                WHERE symbol = ? AND timeframe = ?
            `).bind(symbol, timeframe).first<{ 
                candles_json: string; 
                cached_at: number;
                provider: string | null;
            }>();

            if (result && (now - result.cached_at) < maxCacheAge) {
                const candles = JSON.parse(result.candles_json) as CandleData[];
                const provider = (result.provider || 'yahoo') as DataProvider;
                return { candles, provider };
            }

            return null;
        } catch (error) {
            console.error('Error getting cached candles from D1:', error);
            return null;
        }
    }

    /**
     * Save candles to cache with provider info
     */
    async setCachedCandles(
        symbol: string,
        timeframe: string,
        candles: CandleData[],
        provider: DataProvider
    ): Promise<void> {
        try {
            const candlesJson = JSON.stringify(candles);
            const cachedAt = Date.now();

            await this.db.prepare(`
                INSERT INTO candles_cache (symbol, timeframe, candles_json, cached_at, provider)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(symbol, timeframe) 
                DO UPDATE SET candles_json = ?, cached_at = ?, provider = ?
            `).bind(
                symbol, 
                timeframe, 
                candlesJson, 
                cachedAt, 
                provider,
                candlesJson, 
                cachedAt, 
                provider
            ).run();

            // Clean up old cache entries (older than 5 minutes)
            const fiveMinutesAgo = Date.now() - 5 * 60 * 1000;
            await this.db.prepare(`
                DELETE FROM candles_cache 
                WHERE cached_at < ?
            `).bind(fiveMinutesAgo).run();
        } catch (error) {
            console.error('Error caching candles in D1:', error);
        }
    }
}
