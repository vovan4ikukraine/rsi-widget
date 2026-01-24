import type { CandleData, QuoteData, SymbolInfo } from './yahoo-service';

/**
 * BinanceService: Fetches market data from Binance API
 * 
 * Binance API endpoints:
 * - Klines: https://api.binance.com/api/v3/klines
 * - Ticker: https://api.binance.com/api/v3/ticker/24hr
 * - Exchange Info: https://api.binance.com/api/v3/exchangeInfo
 * 
 * Rate Limits:
 * - 1200 requests per minute (weight-based)
 * - Klines: 1 weight per request
 */
export class BinanceService {
    private readonly baseUrl = 'https://api.binance.com/api/v3';

    /**
     * Get candles for symbol
     * 
     * @param symbol Binance symbol (e.g., BTCUSDT)
     * @param timeframe Timeframe (1m, 5m, 15m, 1h, 4h, 1d, etc.)
     * @param options Options including since (timestamp) and limit
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
            const interval = this.getBinanceInterval(timeframe);
            if (!interval) {
                throw new Error(`Unsupported timeframe: ${timeframe}`);
            }

            // Binance API parameters
            const params = new URLSearchParams();
            params.append('symbol', symbol);
            params.append('interval', interval);
            
            // Binance limit: max 1000 candles per request
            const limit = options.limit ? Math.min(options.limit, 1000) : 500;
            params.append('limit', limit.toString());

            // If since is provided, calculate startTime
            if (options.since) {
                // Binance expects milliseconds
                params.append('startTime', options.since.toString());
            }

            const url = `${this.baseUrl}/klines?${params.toString()}`;

            console.log(`Requesting Binance candles for ${symbol} ${timeframe}: ${url}`);

            const response = await fetch(url, {
                headers: {
                    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
                },
            });

            if (!response.ok) {
                const errorText = await response.text();
                throw new Error(`Binance API error: ${response.status} - ${errorText}`);
            }

            const data = await response.json() as any[];

            if (!Array.isArray(data) || data.length === 0) {
                throw new Error('No data available from Binance');
            }

            // Binance klines format: [timestamp, open, high, low, close, volume, ...]
            const candles: CandleData[] = [];

            for (const kline of data) {
                if (kline.length < 6) {
                    continue;
                }

                const timestamp = kline[0] as number; // Already in milliseconds
                const open = parseFloat(kline[1] as string);
                const high = parseFloat(kline[2] as string);
                const low = parseFloat(kline[3] as string);
                const close = parseFloat(kline[4] as string);
                const volume = parseFloat(kline[5] as string);

                // Skip invalid candles
                if (!isFinite(open) || !isFinite(high) || !isFinite(low) || !isFinite(close)) {
                    continue;
                }

                candles.push({
                    timestamp: timestamp,
                    open: open,
                    high: high,
                    low: low,
                    close: close,
                    volume: volume || 0,
                });
            }

            console.log(`Fetched ${candles.length} candles from Binance for ${symbol} ${timeframe}`);

            return candles;
        } catch (error) {
            console.error(`Error fetching Binance candles for ${symbol}:`, error);
            throw error;
        }
    }

    /**
     * Get current price (24hr ticker)
     */
    async getQuote(symbol: string): Promise<QuoteData> {
        try {
            const url = `${this.baseUrl}/ticker/24hr?symbol=${symbol}`;

            const response = await fetch(url, {
                headers: {
                    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
                },
            });

            if (!response.ok) {
                const errorText = await response.text();
                throw new Error(`Binance API error: ${response.status} - ${errorText}`);
            }

            const data = await response.json() as any;

            const price = parseFloat(data.lastPrice);
            const openPrice = parseFloat(data.openPrice);
            const change = price - openPrice;
            const changePercent = openPrice !== 0 ? (change / openPrice) * 100 : 0;

            return {
                symbol: symbol,
                price: price,
                change: change,
                changePercent: changePercent,
                timestamp: Date.now(),
            };
        } catch (error) {
            console.error(`Error fetching Binance quote for ${symbol}:`, error);
            throw error;
        }
    }

    /**
     * Get symbol information
     */
    async getSymbolInfo(symbol: string): Promise<SymbolInfo> {
        try {
            // Binance doesn't have a direct symbol info endpoint
            // We'll use exchangeInfo to get symbol details
            const url = `${this.baseUrl}/exchangeInfo?symbol=${symbol}`;

            const response = await fetch(url, {
                headers: {
                    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
                },
            });

            if (!response.ok) {
                const errorText = await response.text();
                throw new Error(`Binance API error: ${response.status} - ${errorText}`);
            }

            const data = await response.json() as any;

            if (!data.symbols || data.symbols.length === 0) {
                throw new Error('Symbol not found on Binance');
            }

            const symbolInfo = data.symbols[0];

            return {
                symbol: symbolInfo.symbol,
                name: symbolInfo.baseAsset + '/' + symbolInfo.quoteAsset,
                type: 'crypto',
                currency: symbolInfo.quoteAsset,
                exchange: 'Binance',
            };
        } catch (error) {
            console.error(`Error fetching Binance symbol info for ${symbol}:`, error);
            throw error;
        }
    }

    /**
     * Convert timeframe to Binance interval
     * 
     * Binance supports: 1m, 3m, 5m, 15m, 30m, 1h, 2h, 4h, 6h, 8h, 12h, 1d, 3d, 1w, 1M
     */
    private getBinanceInterval(timeframe: string): string | null {
        const intervals: Record<string, string> = {
            '1m': '1m',
            '5m': '5m',
            '15m': '15m',
            '30m': '30m',
            '1h': '1h',
            '4h': '4h',
            '1d': '1d',
            '1w': '1w',
            '1M': '1M',
        };

        return intervals[timeframe] || null;
    }
}
