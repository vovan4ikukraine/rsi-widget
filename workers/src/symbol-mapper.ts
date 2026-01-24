/**
 * SymbolMapper: Converts between Yahoo Finance and Binance symbol formats
 * 
 * Yahoo format: BTC-USD, ETH-USD (crypto)
 * Binance format: BTCUSDT, ETHUSDT (crypto)
 * 
 * For non-crypto symbols, returns null (no conversion needed)
 */
export class SymbolMapper {
    /**
     * Check if symbol is cryptocurrency
     */
    static isCrypto(symbol: string): boolean {
        // Yahoo crypto format: ends with -USD (e.g., BTC-USD, ETH-USD)
        return symbol.includes('-USD') && !symbol.includes('=X') && !symbol.includes('=F');
    }

    /**
     * Convert Yahoo symbol to Binance symbol
     * BTC-USD -> BTCUSDT
     * ETH-USD -> ETHUSDT
     * Returns null if not crypto or conversion not possible
     */
    static yahooToBinance(symbol: string): string | null {
        if (!this.isCrypto(symbol)) {
            return null;
        }

        // Extract base currency (e.g., BTC from BTC-USD)
        const parts = symbol.split('-USD');
        if (parts.length !== 2 || parts[0].length === 0) {
            return null;
        }

        const baseCurrency = parts[0].toUpperCase();
        // Binance uses USDT as quote currency for most pairs
        return `${baseCurrency}USDT`;
    }

    /**
     * Convert Binance symbol to Yahoo symbol
     * BTCUSDT -> BTC-USD
     * ETHUSDT -> ETH-USD
     * Returns null if conversion not possible
     */
    static binanceToYahoo(symbol: string): string | null {
        // Binance crypto format: ends with USDT (e.g., BTCUSDT, ETHUSDT)
        if (!symbol.endsWith('USDT')) {
            return null;
        }

        const baseCurrency = symbol.slice(0, -4).toUpperCase(); // Remove 'USDT'
        if (baseCurrency.length === 0) {
            return null;
        }

        // Yahoo format: BASE-USD
        return `${baseCurrency}-USD`;
    }

    /**
     * Get list of common crypto symbols for validation
     * This can be extended if needed
     */
    static getCommonCryptoSymbols(): string[] {
        return [
            'BTC-USD', 'ETH-USD', 'BNB-USD', 'SOL-USD', 'ADA-USD',
            'XRP-USD', 'DOGE-USD', 'DOT-USD', 'MATIC-USD', 'AVAX-USD',
            'LINK-USD', 'UNI-USD', 'LTC-USD', 'ATOM-USD', 'ETC-USD'
        ];
    }
}
