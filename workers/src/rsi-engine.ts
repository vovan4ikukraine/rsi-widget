import { YahooService } from './yahoo-service';

export interface AlertRule {
    id: number;
    user_id: string;
    symbol: string;
    timeframe: string;
    indicator?: string;  // Type of indicator: 'rsi', 'stoch', etc.
    period?: number;     // Universal period (replaces rsi_period)
    indicator_params?: string;  // JSON with additional parameters
    rsi_period?: number;  // Deprecated: kept for backward compatibility
    levels: number[];
    mode: string;
    cooldown_sec: number;
    active: number;
    created_at: number;
}

export interface AlertState {
    rule_id: number;
    last_indicator_value?: number;  // Universal: last calculated indicator value
    indicator_state?: string;       // JSON: state for incremental calculation
    last_bar_ts?: number;
    last_fire_ts?: number;
    last_side?: string;
    // Deprecated fields (kept for backward compatibility)
    last_rsi?: number;
    last_au?: number;
    last_ad?: number;
}

export interface AlertTrigger {
    ruleId: number;
    userId: string;
    symbol: string;
    indicatorValue: number;  // Universal: indicator value that triggered
    indicator?: string;      // Optional: indicator type
    level: number;
    type: 'cross_up' | 'cross_down' | 'enter_zone' | 'exit_zone';
    timestamp: number;
    message: string;
    // Deprecated (kept for backward compatibility)
    rsi?: number;
}

export class IndicatorEngine {
    constructor(
        private db: D1Database,
        private yahooService: YahooService,
        private kv?: KVNamespace
    ) { }

    /**
     * Get active alert rules
     */
    async getActiveRules(): Promise<AlertRule[]> {
        const result = await this.db.prepare(`
      SELECT * FROM alert_rule 
      WHERE active = 1 
      ORDER BY created_at DESC
    `).all();

        return result.results.map((row: any) => ({
            ...row,
            indicator: row.indicator || 'rsi',  // Default to 'rsi' for backward compatibility
            period: row.period || row.rsi_period || 14,  // Use period, fallback to rsi_period
            indicator_params: row.indicator_params ? JSON.parse(row.indicator_params) : undefined,
            levels: JSON.parse(row.levels || '[]'),
        })) as AlertRule[];
    }

    /**
     * Group rules by symbol and timeframe
     */
    groupRulesBySymbolTimeframe(rules: AlertRule[]): Record<string, AlertRule[]> {
        const grouped: Record<string, AlertRule[]> = {};

        for (const rule of rules) {
            const key = `${rule.symbol}|${rule.timeframe}`;
            if (!grouped[key]) {
                grouped[key] = [];
            }
            grouped[key].push(rule);
        }

        return grouped;
    }

    /**
     * Check alerts for specific symbol and timeframe
     */
    async checkSymbolTimeframe(
        symbol: string,
        timeframe: string,
        rules: AlertRule[]
    ): Promise<AlertTrigger[]> {
        const triggers: AlertTrigger[] = [];

        try {
            // Get candles - try cache first, then Yahoo
            let candles: any[] = [];

            if (this.kv) {
                const cached = await this.yahooService.getCachedCandles(symbol, timeframe, this.kv);
                if (cached && cached.length > 0) {
                    candles = cached;
                    console.log(`RSI Engine: Using cached candles for ${symbol} ${timeframe} (${candles.length} candles)`);
                }
            }

            // If no cache or cache miss, fetch from Yahoo
            if (candles.length === 0) {
                try {
                    candles = await this.yahooService.getCandles(symbol, timeframe, {
                        limit: 1000
                    });

                    // Save to cache for future use
                    if (this.kv && candles.length > 0) {
                        await this.yahooService.setCachedCandles(symbol, timeframe, candles, this.kv);
                        console.log(`RSI Engine: Fetched and cached ${candles.length} candles for ${symbol} ${timeframe}`);
                    }
                } catch (error: any) {
                    // If rate limited (429), rethrow to trigger backoff in caller
                    if (error?.message?.includes('429') || error?.status === 429) {
                        throw new Error(`Rate limited: ${symbol} ${timeframe}`);
                    }
                    throw error;
                }
            }

            if (candles.length < 2) {
                console.log(`Not enough candles for ${symbol} ${timeframe}`);
                return triggers;
            }

            // Check each rule
            for (const rule of rules) {
                try {
                    const ruleTriggers = await this.checkRule(rule, candles);
                    triggers.push(...ruleTriggers);
                } catch (error) {
                    console.error(`Error checking rule ${rule.id}:`, error);
                }
            }

        } catch (error) {
            console.error(`Error checking ${symbol} ${timeframe}:`, error);
        }

        return triggers;
    }

    /**
     * Check specific rule (universal for all indicators)
     */
    async checkRule(rule: AlertRule, candles: any[]): Promise<AlertTrigger[]> {
        const triggers: AlertTrigger[] = [];

        try {
            // Get rule state
            const state = await this.getAlertState(rule.id);

            // Determine indicator type and period
            const indicator = rule.indicator || 'rsi';
            const period = rule.period || rule.rsi_period || 14;

            // Calculate indicator value(s)
            const indicatorData = this.calculateIndicator(candles, indicator, period, rule.indicator_params);

            if (indicatorData.length < 2) {
                console.log(`Rule ${rule.id}: not enough indicator data (size=${indicatorData.length})`);
                return triggers;
            }

            const currentValue = indicatorData[indicatorData.length - 1].value;
            const previousValue = state.last_indicator_value ?? state.last_rsi ?? indicatorData[indicatorData.length - 2].value;
            console.log(`Rule ${rule.id} (${rule.symbol} ${rule.timeframe}) ${indicator.toUpperCase()}=${currentValue.toFixed(2)}, previous=${previousValue.toFixed(2)}, levels=${rule.levels}, mode=${rule.mode}, cooldown=${rule.cooldown_sec}`);

            // Check crossings
            const ruleTriggers = this.checkCrossings(
                rule,
                currentValue,
                previousValue,
                Date.now(),
                indicator
            );
            if (ruleTriggers.length === 0) {
                console.log(`Rule ${rule.id}: no trigger this run`);
            }

            // Always update indicator state to prevent duplicate triggers
            const stateUpdates: Partial<AlertState> = {
                last_indicator_value: currentValue,
                last_rsi: currentValue,  // Keep for backward compatibility
                last_bar_ts: candles[candles.length - 1].timestamp,
            };

            // Save indicator state if available (for incremental calculations)
            if (indicatorData.length > 0 && indicatorData[0].state) {
                stateUpdates.indicator_state = JSON.stringify(indicatorData[0].state);
            }

            if (ruleTriggers.length > 0) {
                // Check cooldown
                const canFire = this.checkCooldown(rule, state);
                console.log(`Rule ${rule.id}: cooldown check -> ${canFire}`);

                if (canFire) {
                    // Save state with fire timestamp
                    stateUpdates.last_fire_ts = Date.now();
                    stateUpdates.last_side = this.getIndicatorZone(currentValue, rule.levels);

                    // Save events
                    for (const trigger of ruleTriggers) {
                        await this.saveAlertEvent(rule.id, trigger);
                    }

                    triggers.push(...ruleTriggers);
                }
                // Even if cooldown blocks firing, update indicator state to prevent duplicate detection
            }

            // Update state regardless of whether triggers fired
            await this.updateAlertState(rule.id, stateUpdates);

        } catch (error) {
            console.error(`Error checking rule ${rule.id}:`, error);
        }
        console.log(`Rule ${rule.id}: total triggers collected ${triggers.length}`);

        return triggers;
    }

    /**
     * Calculate indicator value(s) - universal method for all indicators
     * Returns array of objects with {value: number, state?: any}
     */
    calculateIndicator(candles: any[], indicator: string, period: number, indicatorParams?: any): Array<{ value: number, state?: any }> {
        switch (indicator.toLowerCase()) {
            case 'rsi':
                return this.calculateRsi(candles, period).map(v => ({ value: v }));
            case 'stoch':
                return this.calculateStochastic(candles, period, indicatorParams);
            case 'macd':
                return this.calculateMacd(candles, period, indicatorParams);
            case 'bollinger':
                return this.calculateBollinger(candles, period, indicatorParams);
            case 'williams':
                return this.calculateWilliams(candles, period).map(v => ({ value: v }));
            default:
                // Default to RSI for unknown indicators
                return this.calculateRsi(candles, period).map(v => ({ value: v }));
        }
    }

    /**
     * Calculate RSI using Wilder's algorithm
     */
    calculateRsi(candles: any[], period: number): number[] {
        if (candles.length < period + 1) {
            return [];
        }

        const closes = candles.map(c => c.close);
        const rsiValues: number[] = [];

        // Initial calculation
        let gain = 0, loss = 0;
        for (let i = 1; i <= period; i++) {
            const change = closes[i] - closes[i - 1];
            if (change > 0) gain += change;
            else loss -= change;
        }

        let au = gain / period;
        let ad = loss / period;

        // Incremental calculation
        for (let i = period + 1; i < closes.length; i++) {
            const change = closes[i] - closes[i - 1];
            const u = change > 0 ? change : 0;
            const d = change < 0 ? -change : 0;

            au = (au * (period - 1) + u) / period;
            ad = (ad * (period - 1) + d) / period;

            const rs = ad === 0 ? Infinity : au / ad;
            const rsi = 100 - (100 / (1 + rs));
            rsiValues.push(Math.max(0, Math.min(100, rsi)));
        }

        return rsiValues;
    }

    /**
     * Calculate Stochastic Oscillator (%K and %D)
     */
    calculateStochastic(candles: any[], kPeriod: number, params?: any): Array<{ value: number, state?: any }> {
        const dPeriod = params?.dPeriod || 3;
        if (candles.length < kPeriod + dPeriod - 1) {
            return [];
        }

        const highs = candles.map(c => c.high);
        const lows = candles.map(c => c.low);
        const closes = candles.map(c => c.close);
        const kValues: number[] = [];

        // Calculate %K values
        for (let i = kPeriod - 1; i < candles.length; i++) {
            const periodHighs = highs.slice(i - kPeriod + 1, i + 1);
            const periodLows = lows.slice(i - kPeriod + 1, i + 1);

            const highestHigh = Math.max(...periodHighs);
            const lowestLow = Math.min(...periodLows);
            const close = closes[i];

            if (highestHigh === lowestLow) {
                kValues.push(50.0);
            } else {
                const k = ((close - lowestLow) / (highestHigh - lowestLow)) * 100.0;
                kValues.push(Math.max(0, Math.min(100, k)));
            }
        }

        if (kValues.length === 0) {
            return [];
        }

        // Calculate %D (smoothed %K) and return %K values
        const result: Array<{ value: number, state?: any }> = [];
        for (let i = 0; i < kValues.length; i++) {
            const k = kValues[i];
            let d: number | undefined;

            if (i >= dPeriod - 1) {
                const dPeriodValues = kValues.slice(i - dPeriod + 1, i + 1);
                d = dPeriodValues.reduce((a, b) => a + b, 0) / dPeriod;
            } else {
                const availableValues = kValues.slice(0, i + 1);
                d = availableValues.reduce((a, b) => a + b, 0) / availableValues.length;
            }

            result.push({
                value: k,  // Use %K as main value
                state: { k, d }  // Store both %K and %D in state
            });
        }

        return result;
    }

    /**
     * Calculate MACD (placeholder - to be implemented)
     */
    calculateMacd(_candles: any[], _fastPeriod: number, _params?: any): Array<{ value: number, state?: any }> {
        // TODO: Implement MACD calculation
        // For now, return empty array
        return [];
    }

    /**
     * Calculate Bollinger Bands (placeholder - to be implemented)
     */
    calculateBollinger(_candles: any[], _period: number, _params?: any): Array<{ value: number, state?: any }> {
        // TODO: Implement Bollinger Bands calculation
        // For now, return empty array
        return [];
    }

    /**
     * Calculate Williams %R (placeholder - to be implemented)
     */
    calculateWilliams(_candles: any[], _period: number): number[] {
        // TODO: Implement Williams %R calculation
        // For now, return empty array
        return [];
    }

    /**
     * Check level crossings (universal for all indicators)
     */
    checkCrossings(
        rule: AlertRule,
        currentValue: number,
        previousValue: number,
        timestamp: number,
        indicator: string = 'rsi'
    ): AlertTrigger[] {
        const triggers: AlertTrigger[] = [];
        const indicatorName = indicator.toUpperCase();

        if (rule.mode === 'cross') {
            for (const level of rule.levels) {
                // Upward crossing
                if (this.checkCrossUp(currentValue, previousValue, level)) {
                    triggers.push({
                        ruleId: rule.id,
                        userId: rule.user_id,
                        symbol: rule.symbol,
                        indicatorValue: currentValue,
                        indicator: indicator,
                        rsi: currentValue,  // Keep for backward compatibility
                        level: level,
                        type: 'cross_up',
                        timestamp: timestamp,
                        message: `${indicatorName} crossed level ${level} upward (${currentValue.toFixed(1)})`
                    });
                }

                // Downward crossing
                if (this.checkCrossDown(currentValue, previousValue, level)) {
                    triggers.push({
                        ruleId: rule.id,
                        userId: rule.user_id,
                        symbol: rule.symbol,
                        indicatorValue: currentValue,
                        indicator: indicator,
                        rsi: currentValue,  // Keep for backward compatibility
                        level: level,
                        type: 'cross_down',
                        timestamp: timestamp,
                        message: `${indicatorName} crossed level ${level} downward (${currentValue.toFixed(1)})`
                    });
                }
            }
        } else if (rule.mode === 'enter' && rule.levels.length >= 2) {
            if (this.checkEnterZone(
                currentValue,
                previousValue,
                rule.levels[0],
                rule.levels[1]
            )) {
                triggers.push({
                    ruleId: rule.id,
                    userId: rule.user_id,
                    symbol: rule.symbol,
                    indicatorValue: currentValue,
                    indicator: indicator,
                    rsi: currentValue,  // Keep for backward compatibility
                    level: rule.levels[1],
                    type: 'enter_zone',
                    timestamp: timestamp,
                    message: `${indicatorName} entered zone ${rule.levels[0]}-${rule.levels[1]} (${currentValue.toFixed(1)})`
                });
            }
        } else if (rule.mode === 'exit' && rule.levels.length >= 2) {
            if (this.checkExitZone(
                currentValue,
                previousValue,
                rule.levels[0],
                rule.levels[1]
            )) {
                triggers.push({
                    ruleId: rule.id,
                    userId: rule.user_id,
                    symbol: rule.symbol,
                    indicatorValue: currentValue,
                    indicator: indicator,
                    rsi: currentValue,  // Keep for backward compatibility
                    level: rule.levels[1],
                    type: 'exit_zone',
                    timestamp: timestamp,
                    message: `${indicatorName} exited zone ${rule.levels[0]}-${rule.levels[1]} (${currentValue.toFixed(1)})`
                });
            }
        }

        return triggers;
    }

    /**
     * Check upward crossing
     */
    checkCrossUp(currentRsi: number, previousRsi: number, level: number): boolean {
        return previousRsi <= level && currentRsi > level;
    }

    /**
     * Check downward crossing
     */
    checkCrossDown(currentRsi: number, previousRsi: number, level: number): boolean {
        return previousRsi >= level && currentRsi < level;
    }

    /**
     * Check zone entry
     */
    checkEnterZone(
        currentRsi: number,
        previousRsi: number,
        lowerLevel: number,
        upperLevel: number
    ): boolean {
        const wasOutside = previousRsi < lowerLevel || previousRsi > upperLevel;
        const isInside = currentRsi >= lowerLevel && currentRsi <= upperLevel;

        return wasOutside && isInside;
    }

    /**
     * Check zone exit
     */
    checkExitZone(
        currentRsi: number,
        previousRsi: number,
        lowerLevel: number,
        upperLevel: number
    ): boolean {
        const wasInside = previousRsi >= lowerLevel && previousRsi <= upperLevel;
        const isOutside = currentRsi < lowerLevel || currentRsi > upperLevel;

        return wasInside && isOutside;
    }

    /**
     * Check cooldown
     */
    checkCooldown(rule: AlertRule, state: AlertState): boolean {
        if (!state.last_fire_ts) return true;

        const timeSinceLastFire = Date.now() - state.last_fire_ts;
        return timeSinceLastFire >= (rule.cooldown_sec * 1000);
    }

    /**
     * Determine indicator zone (universal for all indicators)
     */
    getIndicatorZone(value: number, levels: number[]): string {
        if (levels.length === 0) return 'between';

        const lowerLevel = levels[0];
        const upperLevel = levels.length > 1 ? levels[1] : 100;

        if (value < lowerLevel) return 'below';
        if (value > upperLevel) return 'above';
        return 'between';
    }

    /**
     * Deprecated: Use getIndicatorZone instead
     */
    getRsiZone(rsi: number, levels: number[]): string {
        return this.getIndicatorZone(rsi, levels);
    }

    /**
     * Get alert state
     */
    async getAlertState(ruleId: number): Promise<AlertState> {
        const result = await this.db.prepare(`
          SELECT * FROM alert_state WHERE rule_id = ?
        `).bind(ruleId).first();

        const state = (result as unknown as AlertState) || {
            rule_id: ruleId,
            last_indicator_value: undefined,
            last_rsi: undefined,
            last_bar_ts: undefined,
            last_fire_ts: undefined,
            last_side: undefined,
        };

        // Migrate last_rsi to last_indicator_value if needed
        if (state.last_rsi !== undefined && state.last_indicator_value === undefined) {
            state.last_indicator_value = state.last_rsi;
        }

        return state;
    }

    /**
     * Update alert state
     */
    async updateAlertState(ruleId: number, updates: Partial<AlertState>): Promise<void> {
        const columns = Object.keys(updates);
        if (columns.length === 0) {
            return;
        }
        const values = columns.map((key) => (updates as any)[key]);
        const assignments = columns.map((col) => `${col}=excluded.${col}`).join(', ');
        const placeholders = columns.map(() => '?').join(', ');

        await this.db.prepare(`
          INSERT INTO alert_state (rule_id, ${columns.join(', ')})
          VALUES (?, ${placeholders})
          ON CONFLICT(rule_id) DO UPDATE SET ${assignments}
        `).bind(ruleId, ...values).run();
    }

    /**
     * Save alert event (universal for all indicators)
     */
    async saveAlertEvent(ruleId: number, trigger: AlertTrigger): Promise<void> {
        await this.db.prepare(`
      INSERT INTO alert_event (rule_id, ts, indicator_value, indicator, rsi, level, side, bar_ts, symbol)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    `).bind(
            ruleId,
            trigger.timestamp,
            trigger.indicatorValue,
            trigger.indicator || 'rsi',
            trigger.rsi || trigger.indicatorValue,  // Keep rsi for backward compatibility
            trigger.level,
            trigger.type,
            trigger.timestamp,
            trigger.symbol
        ).run();
    }

    /**
     * Check alerts for list of symbols
     */
    async checkAlerts(symbols: string[], timeframes: string[]): Promise<any> {
        const results: any = {};

        for (const symbol of symbols) {
            results[symbol] = {};

            for (const timeframe of timeframes) {
                try {
                    const rules = await this.getRulesForSymbolTimeframe(symbol, timeframe);

                    if (rules.length > 0) {
                        const triggers = await this.checkSymbolTimeframe(symbol, timeframe, rules);
                        results[symbol][timeframe] = triggers;
                    }
                } catch (error) {
                    console.error(`Error checking ${symbol} ${timeframe}:`, error);
                    results[symbol][timeframe] = { error: error instanceof Error ? error.message : String(error) };
                }
            }
        }

        return results;
    }

    /**
     * Get rules for symbol and timeframe
     */
    async getRulesForSymbolTimeframe(symbol: string, timeframe: string): Promise<AlertRule[]> {
        const result = await this.db.prepare(`
      SELECT * FROM alert_rule 
      WHERE symbol = ? AND timeframe = ? AND active = 1
    `).bind(symbol, timeframe).all();

        return result.results.map((row: any) => ({
            ...row,
            levels: JSON.parse(row.levels || '[]'),
        })) as AlertRule[];
    }
}
