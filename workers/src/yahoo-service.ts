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
     * Получение свечей для символа
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

            // Используем period1 и period2 для явного указания периода
            // Это гарантирует получение достаточного количества торговых дней
            const now = Math.floor(Date.now() / 1000); // Unix timestamp в секундах
            let period1: number;
            let period2: number = now;

            if (timeframe === '4h') {
                // Для 4h нужно минимум 15 свечей
                // В торговый день обычно 1-2 свечи 4h (зависит от времени открытия/закрытия)
                // Берем 2 года назад для гарантии получения достаточного количества торговых дней
                // 2 года = ~730 календарных дней = ~500 торговых дней = более чем достаточно
                period1 = now - (730 * 24 * 60 * 60); // 730 дней назад (2 года)
            } else if (timeframe === '1d') {
                // Для 1d нужно минимум 15 торговых дней
                // Берем 2 года назад для гарантии (около 500 торговых дней)
                period1 = now - (730 * 24 * 60 * 60); // 730 дней назад (2 года)
            } else if (timeframe === '1h') {
                period1 = now - (60 * 24 * 60 * 60); // 60 дней назад
            } else {
                // Для минутных таймфреймов используем короткий период
                period1 = now - (5 * 24 * 60 * 60); // 5 дней назад
            }

            // Формируем URL с period1 и period2
            // Используем period1/period2 вместо range для точного контроля периода
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

            // Логируем количество полученных свечей для отладки
            console.log(`Fetched ${candles.length} candles for ${symbol} ${timeframe} (period1: ${new Date(period1 * 1000).toISOString()}, period2: ${new Date(period2 * 1000).toISOString()})`);

            // Фильтрация по лимиту (берем последние N свечей)
            if (options.limit && candles.length > options.limit) {
                const filtered = candles.slice(-options.limit);
                console.log(`Filtered to ${filtered.length} candles (limit: ${options.limit})`);
                return filtered;
            }

            // Если для больших таймфреймов нет данных, возвращаем пустой массив
            // вместо ошибки - клиент сам обработает это
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
     * Получение текущей цены
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
     * Получение информации о символе
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
     * Поиск символов
     */
    async searchSymbols(query: string): Promise<SymbolInfo[]> {
        try {
            // Простой поиск по популярным символам
            const popularSymbols = [
                // Акции США - Технологии
                'AAPL', 'MSFT', 'GOOGL', 'GOOG', 'AMZN', 'TSLA', 'META', 'NVDA', 'NFLX',
                'AMD', 'INTC', 'CRM', 'ADBE', 'PYPL', 'UBER', 'SQ', 'NOW', 'SNOW',
                'PLTR', 'RBLX', 'COIN', 'HOOD', 'SOFI', 'AFRM', 'UPST',

                // Акции США - Финансы
                'JPM', 'BAC', 'WFC', 'GS', 'MS', 'C', 'BLK', 'SCHW',

                // Акции США - Потребительские товары
                'WMT', 'TGT', 'HD', 'NKE', 'SBUX', 'MCD', 'DIS', 'NFLX',

                // Акции США - Энергетика
                'XOM', 'CVX', 'COP', 'SLB', 'EOG',

                // Акции США - Здравоохранение
                'JNJ', 'PFE', 'UNH', 'ABBV', 'TMO', 'ABT', 'MRK',

                // Индексы
                '^GSPC', '^DJI', '^IXIC', '^RUT',

                // Форекс - Major pairs
                'EURUSD=X', 'GBPUSD=X', 'USDJPY=X', 'AUDUSD=X', 'USDCAD=X',
                'USDCHF=X', 'NZDUSD=X', 'EURGBP=X', 'EURJPY=X', 'GBPJPY=X',
                'EURCHF=X', 'AUDJPY=X', 'NZDJPY=X', 'CADJPY=X', 'CHFJPY=X',

                // Форекс - Cross pairs
                'EURCAD=X', 'EURAUD=X', 'EURNZD=X', 'GBPCAD=X', 'GBPAUD=X',
                'GBPNZD=X', 'AUDCAD=X', 'AUDNZD=X', 'CADCHF=X',

                // Криптовалюты
                'BTC-USD', 'ETH-USD', 'BNB-USD', 'ADA-USD', 'SOL-USD',
                'XRP-USD', 'DOGE-USD', 'DOT-USD', 'MATIC-USD', 'AVAX-USD',
                'LINK-USD', 'UNI-USD', 'ATOM-USD', 'ALGO-USD', 'VET-USD',

                // Товары
                'GC=F', 'SI=F', 'CL=F', 'NG=F', 'ZC=F', 'ZS=F',

                // ETF
                'SPY', 'QQQ', 'DIA', 'IWM', 'GLD', 'SLV',
            ];

            const results = popularSymbols
                .filter(symbol =>
                    symbol.toLowerCase().includes(query.toLowerCase()) ||
                    symbol.includes(query.toUpperCase())
                )
                .slice(0, 10);

            const symbolInfos: SymbolInfo[] = [];

            for (const symbol of results) {
                try {
                    const info = await this.getSymbolInfo(symbol);
                    symbolInfos.push(info);
                } catch (error) {
                    console.error(`Error fetching info for ${symbol}:`, error);
                }
            }

            return symbolInfos;
        } catch (error) {
            console.error(`Error searching symbols for ${query}:`, error);
            return [];
        }
    }

    /**
     * Преобразование таймфрейма в интервал Yahoo
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
     * Определение типа символа
     */
    private getSymbolType(symbol: string): string {
        if (symbol.includes('=X')) return 'forex';
        if (symbol.includes('-USD')) return 'crypto';
        return 'stock';
    }

    /**
     * Кэширование данных
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

                // Кэш действителен 5 минут
                if (now - cacheTime < 5 * 60 * 1000) {
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
     * Сохранение данных в кэш
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
