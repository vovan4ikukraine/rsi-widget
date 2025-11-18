export interface CandleData {
    timestamp: number;
    open: number;
    high: number;
    low: number;
    close: number;
    volume: number;
}

export interface QuoteData {
    symbol: string;
    price: number;
    change: number;
    changePercent: number;
    timestamp: number;
}

export interface SymbolInfo {
    symbol: string;
    name: string;
    type: string;
    currency: string;
    exchange: string;
}

export class YahooService {
    constructor(private endpoint: string) { }

    /**
     * Get candles for symbol
     */
    async getCandles(
        symbol: string,
        timeframe: string,
        options: {
            since?: number;
            limit?: number;
        } = {}
    ): Promise<CandleData[]> {
        try {
            const interval = this.getYahooInterval(timeframe);

            // Use period1 and period2 for explicit period specification
            // This guarantees getting sufficient number of trading days
            const now = Math.floor(Date.now() / 1000); // Unix timestamp in seconds
            let period1: number;
            let period2: number = now;

            if (timeframe === '4h') {
                // For 4h need at least 15 candles
                // In a trading day usually 1-2 4h candles (depends on open/close time)
                // Take 2 years ago to guarantee getting sufficient number of trading days
                // 2 years = ~730 calendar days = ~500 trading days = more than enough
                period1 = now - (730 * 24 * 60 * 60); // 730 days ago (2 years)
            } else if (timeframe === '1d') {
                // For 1d need at least 15 trading days
                // Take 2 years ago to guarantee (about 500 trading days)
                period1 = now - (730 * 24 * 60 * 60); // 730 days ago (2 years)
            } else if (timeframe === '1h') {
                period1 = now - (60 * 24 * 60 * 60); // 60 days ago
            } else {
                // For minute timeframes use short period
                period1 = now - (5 * 24 * 60 * 60); // 5 days ago
            }

            // Build URL with period1 and period2
            // Use period1/period2 instead of range for precise period control
            const url = `https://query1.finance.yahoo.com/v8/finance/chart/${symbol}?interval=${interval}&period1=${period1}&period2=${period2}`;

            console.log(`Requesting candles for ${symbol} ${timeframe}: period1=${period1} (${new Date(period1 * 1000).toISOString()}), period2=${period2} (${new Date(period2 * 1000).toISOString()}), interval=${interval}`);

            const response = await fetch(url, {
                headers: {
                    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
                },
            });

            if (!response.ok) {
                throw new Error(`Yahoo API error: ${response.status}`);
            }

            const data = await response.json() as any;

            if (!data.chart || !data.chart.result || data.chart.result.length === 0) {
                throw new Error('No data available');
            }

            const result = data.chart.result[0];
            const timestamps = result.timestamp;
            const quotes = result.indicators.quote[0];

            const candles: CandleData[] = [];

            for (let i = 0; i < timestamps.length; i++) {
                if (quotes.open[i] != null && quotes.close[i] != null) {
                    candles.push({
                        timestamp: timestamps[i] * 1000,
                        open: quotes.open[i],
                        high: quotes.high[i],
                        low: quotes.low[i],
                        close: quotes.close[i],
                        volume: quotes.volume[i] || 0,
                    });
                }
            }

            // Log number of fetched candles for debugging
            console.log(`Fetched ${candles.length} candles for ${symbol} ${timeframe} (period1: ${new Date(period1 * 1000).toISOString()}, period2: ${new Date(period2 * 1000).toISOString()})`);

            // Filter by limit (take last N candles)
            if (options.limit && candles.length > options.limit) {
                const filtered = candles.slice(-options.limit);
                console.log(`Filtered to ${filtered.length} candles (limit: ${options.limit})`);
                return filtered;
            }

            // If no data for large timeframes, return empty array
            // instead of error - client will handle it
            if (candles.length === 0 && (timeframe === '4h' || timeframe === '1d')) {
                console.warn(`No candles returned for ${symbol} ${timeframe}. Market might be closed or insufficient historical data.`);
            }

            return candles;
        } catch (error) {
            console.error(`Error fetching candles for ${symbol}:`, error);
            throw error;
        }
    }

    /**
     * Get current price
     */
    async getQuote(symbol: string): Promise<QuoteData> {
        try {
            const url = `${this.endpoint}/${symbol}?interval=1m&range=1d`;

            const response = await fetch(url, {
                headers: {
                    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
                }
            });

            if (!response.ok) {
                throw new Error(`Yahoo API error: ${response.status}`);
            }

            const data = await response.json() as any;

            if (!data.chart || !data.chart.result || data.chart.result.length === 0) {
                throw new Error('No data available');
            }

            const result = data.chart.result[0];
            const meta = result.meta;

            return {
                symbol: meta.symbol,
                price: meta.regularMarketPrice,
                change: meta.regularMarketPrice - meta.previousClose,
                changePercent: ((meta.regularMarketPrice - meta.previousClose) / meta.previousClose) * 100,
                timestamp: meta.regularMarketTime * 1000,
            };
        } catch (error) {
            console.error(`Error fetching quote for ${symbol}:`, error);
            throw error;
        }
    }

    /**
     * Get symbol information
     */
    async getSymbolInfo(symbol: string): Promise<SymbolInfo> {
        try {
            const url = `${this.endpoint}/${symbol}?interval=1d&range=1d`;

            const response = await fetch(url, {
                headers: {
                    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
                }
            });

            if (!response.ok) {
                throw new Error(`Yahoo API error: ${response.status}`);
            }

            const data = await response.json() as any;

            if (!data.chart || !data.chart.result || data.chart.result.length === 0) {
                throw new Error('No data available');
            }

            const result = data.chart.result[0];
            const meta = result.meta;

            return {
                symbol: meta.symbol,
                name: meta.longName || meta.shortName || symbol,
                type: this.getSymbolType(symbol),
                currency: meta.currency || 'USD',
                exchange: meta.exchangeName || 'Unknown',
            };
        } catch (error) {
            console.error(`Error fetching symbol info for ${symbol}:`, error);
            throw error;
        }
    }

    /**
     * Search symbols using Yahoo Finance search API
     */
    async searchSymbols(query: string): Promise<SymbolInfo[]> {
        try {
            // Use Yahoo Finance search API
            const searchUrl = `https://query1.finance.yahoo.com/v1/finance/search?q=${encodeURIComponent(query)}&quotesCount=20&newsCount=0`;

            const response = await fetch(searchUrl, {
                headers: {
                    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
                    'Accept': 'application/json',
                }
            });

            if (!response.ok) {
                console.error(`Yahoo search API error: ${response.status}`);
                return [];
            }

            const data = await response.json() as any;

            if (!data.quotes || !Array.isArray(data.quotes)) {
                return [];
            }

            const symbolInfos: SymbolInfo[] = [];

            for (const quote of data.quotes) {
                try {
                    const symbol = quote.symbol;
                    const name = quote.longname || quote.shortname || quote.name || symbol;
                    const exchange = quote.exchange || 'Unknown';
                    const quoteType = quote.quoteType?.toLowerCase() || 'unknown';

                    // Determine type
                    let type = 'unknown';
                    if (quoteType === 'equity' || quoteType === 'stock') {
                        type = 'equity';
                    } else if (quoteType === 'etf') {
                        type = 'etf';
                    } else if (quoteType === 'index') {
                        type = 'index';
                    } else if (quoteType === 'cryptocurrency' || symbol.includes('-USD')) {
                        type = 'crypto';
                    } else if (symbol.includes('=X')) {
                        type = 'currency';
                    } else if (symbol.includes('=F')) {
                        type = 'commodity';
                    } else {
                        // Fallback to symbol-based detection
                        type = this.getSymbolType(symbol);
                    }

                    const currency = quote.currency || 'USD';

                    symbolInfos.push({
                        symbol: symbol,
                        name: name,
                        type: type,
                        currency: currency,
                        exchange: exchange,
                    });
                } catch (error) {
                    console.error(`Error processing search result:`, error);
                }
            }

            return symbolInfos;
        } catch (error) {
            console.error(`Error searching symbols for ${query}:`, error);
            return [];
        }
    }

    /**
     * Convert timeframe to Yahoo interval
     */
    private getYahooInterval(timeframe: string): string {
        const intervals: Record<string, string> = {
            '1m': '1m',
            '5m': '5m',
            '15m': '15m',
            '30m': '30m',
            '1h': '1h',
            '4h': '4h',
            '1d': '1d',
            '1w': '1wk',
            '1M': '1mo',
        };

        return intervals[timeframe] || '1h';
    }

    /**
     * Determine symbol type
     */
    private getSymbolType(symbol: string): string {
        if (symbol.includes('=X')) return 'forex';
        if (symbol.includes('-USD')) return 'crypto';
        return 'stock';
    }

    /**
     * Data caching
     */
    async getCachedCandles(
        symbol: string,
        timeframe: string,
        kv: KVNamespace
    ): Promise<CandleData[] | null> {
        try {
            const key = `candles:${symbol}:${timeframe}`;
            const cached = await kv.get(key);

            if (cached) {
                const data = JSON.parse(cached);
                const cacheTime = data.timestamp;
                const now = Date.now();

                // Cache valid for 60 seconds
                if (now - cacheTime < 60 * 1000) {
                    return data.candles;
                }
            }

            return null;
        } catch (error) {
            console.error('Error getting cached candles:', error);
            return null;
        }
    }

    /**
     * Save data to cache
     */
    async setCachedCandles(
        symbol: string,
        timeframe: string,
        candles: CandleData[],
        kv: KVNamespace
    ): Promise<void> {
        try {
            const key = `candles:${symbol}:${timeframe}`;
            const data = {
                timestamp: Date.now(),
                candles: candles,
            };

            await kv.put(key, JSON.stringify(data));
        } catch (error) {
            console.error('Error caching candles:', error);
        }
    }
}
