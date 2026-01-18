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
    levels: number[];  // Filtered array without null (for backward compatibility)
    levelsWithNull?: (number | null)[];  // Full array with null [lower, upper] where null = disabled
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

export interface CheckSymbolTimeframeResult {
    triggers: AlertTrigger[];
    cacheHit: boolean;  // true if data came from cache, false if fetched from Yahoo
}

export class IndicatorEngine {
    constructor(
        private db: D1Database,
        private yahooService: YahooService
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

        return result.results.map((row: any) => {
            const parsedLevels = JSON.parse(row.levels || '[]');
            // If levels is stored as array with null, convert to array with 2 elements [lower, upper]
            // where null means disabled level. If stored as single array, keep as is for backward compatibility
            let levelsWithNull: (number | null)[] = [];
            if (Array.isArray(parsedLevels)) {
                if (parsedLevels.length === 2 && (parsedLevels[0] === null || parsedLevels[1] === null || typeof parsedLevels[0] === 'number' || typeof parsedLevels[1] === 'number')) {
                    // Already in [lower, upper] format with possible null
                    levelsWithNull = parsedLevels;
                } else {
                    // Old format: single array with enabled levels only
                    // Convert to [lower, upper] format (assume all are enabled)
                    if (parsedLevels.length === 1) {
                        levelsWithNull = [parsedLevels[0], null]; // Assume single level is lower
                    } else if (parsedLevels.length >= 2) {
                        levelsWithNull = [parsedLevels[0], parsedLevels[1]];
                    } else {
                        levelsWithNull = [null, null];
                    }
                }
            }
            
            return {
                ...row,
                indicator: row.indicator || 'rsi',  // Default to 'rsi' for backward compatibility
                period: row.period || row.rsi_period || 14,  // Use period, fallback to rsi_period
                indicator_params: row.indicator_params ? JSON.parse(row.indicator_params) : undefined,
                levels: parsedLevels.filter((l: any): l is number => l !== null && l !== undefined), // Filter null for backward compatibility
                levelsWithNull: levelsWithNull, // Store full array with null for processing
                mode: row.mode || 'cross',
                cooldown_sec: row.cooldown_sec || 600,
                active: row.active !== undefined ? row.active : 1,
                created_at: row.created_at || Date.now()
            };
        }) as any[];
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
     * Returns triggers and cache hit information for rate limiting optimization
     */
    async checkSymbolTimeframe(
        symbol: string,
        timeframe: string,
        rules: AlertRule[]
    ): Promise<CheckSymbolTimeframeResult> {
        const triggers: AlertTrigger[] = [];
        let cacheHit = false;

        try {
            // Get candles - try D1 cache first (much cheaper than KV), then Yahoo
            let candles: any[] = [];
            let lastCandleTimestamp: number | null = null;

            // Use D1 database for candles cache (much cheaper than KV)
            const cached = await this.yahooService.getCachedCandles(symbol, timeframe, this.db);
            if (cached && cached.length > 0) {
                candles = cached;
                lastCandleTimestamp = candles[candles.length - 1]?.timestamp || null;
                cacheHit = true;
                console.log(`RSI Engine: Using cached candles from D1 for ${symbol} ${timeframe} (${candles.length} candles)`);
            }

            // If no cache or cache miss, fetch from Yahoo
            if (candles.length === 0) {
                try {
                    // Use same candle limit calculation as UI (_candlesLimitForTimeframe)
                    // This ensures RSI values match between UI and CRON
                    // Calculate optimal candle limit based on timeframe and max period
                    
                    // Check max period across all rules for this symbol/timeframe
                    let maxPeriod = 0;  // Start from 0 to find actual max
                    for (const rule of rules) {
                        const rulePeriod = rule.period || rule.rsi_period || 14;
                        if (rulePeriod > maxPeriod) {
                            maxPeriod = rulePeriod;
                        }
                    }
                    // Fallback to 14 if no valid periods found
                    if (maxPeriod === 0) {
                        maxPeriod = 14;
                    }
                    
                    // Minimum candles required for indicators: period + buffer (20 for smoothing and charts)
                    const periodBuffer = maxPeriod + 20;
                    
                    // Base minimums per timeframe (reduced for 4h/1d as they're excessive)
                    let baseMinimum: number;
                    switch (timeframe) {
                        case '4h':
                            baseMinimum = 100; // Same as other timeframes - period-based calculation handles large periods
                            break;
                        case '1d':
                            baseMinimum = 100; // Same as other timeframes - period-based calculation handles large periods
                            break;
                        default:
                            // 1m, 5m, 15m, 1h: base minimum for small periods (100 for charts and stability)
                            baseMinimum = 100;
                            break;
                    }
                    
                    // Return max of period requirement and base minimum
                    const candleLimit = periodBuffer > baseMinimum ? periodBuffer : baseMinimum;
                    
                    candles = await this.yahooService.getCandles(symbol, timeframe, {
                        limit: candleLimit
                    });

                    // Save to D1 cache for future use (much cheaper than KV)
                    if (candles.length > 0) {
                        await this.yahooService.setCachedCandles(symbol, timeframe, candles, this.db);
                        lastCandleTimestamp = candles[candles.length - 1]?.timestamp || null;
                        console.log(`RSI Engine: Fetched and cached ${candles.length} candles (limit=${candleLimit}, period=${maxPeriod}) in D1 for ${symbol} ${timeframe}`);
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
                return { triggers, cacheHit };
            }

            // Smart check: only process alerts if last candle timestamp has changed
            // This avoids unnecessary calculations when data hasn't updated
            const currentLastTimestamp = candles[candles.length - 1]?.timestamp;
            if (currentLastTimestamp && lastCandleTimestamp !== null && currentLastTimestamp === lastCandleTimestamp) {
                // Check if we already processed this candle by checking alert states
                // Process sequentially to avoid CPU burst from parallel DB queries
                let allProcessed = true;
                const ruleStates: Array<{ rule: AlertRule, state: any }> = [];
                for (const rule of rules) {
                    const state = await this.getAlertState(rule.id);
                    ruleStates.push({ rule, state });
                    if (state.last_bar_ts !== currentLastTimestamp) {
                        allProcessed = false;
                        break;
                    }
                }

                if (allProcessed) {
                    // Log current indicator values for debugging/comparison with UI
                    const indicatorValuesLog: string[] = [];
                    for (const { rule, state } of ruleStates) {
                        const indicator = rule.indicator || 'rsi';
                        const period = rule.period || rule.rsi_period || 14;
                        const currentValue = state.last_indicator_value ?? state.last_rsi ?? 'N/A';
                        indicatorValuesLog.push(`Rule ${rule.id}: ${indicator.toUpperCase()}(${period})=${currentValue}`);
                    }
                    console.log(`RSI Engine: Skipping ${symbol} ${timeframe} - last candle already processed (timestamp: ${currentLastTimestamp})`);
                    if (indicatorValuesLog.length > 0) {
                        console.log(`RSI Engine: Current values for skipped rules: ${indicatorValuesLog.join(', ')}`);
                    }
                    return { triggers, cacheHit };
                }
            }

            // Check each rule sequentially to avoid CPU burst from parallel calculations
            // Even with same candles, processing many rules can create microtask bursts
            // Sequential processing already prevents burst without additional delays
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

        return { triggers, cacheHit };
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
            const isFirstCheck = state.last_indicator_value === undefined && state.last_rsi === undefined;
            const previousValue = state.last_indicator_value ?? state.last_rsi ?? indicatorData[indicatorData.length - 2].value;
            console.log(`Rule ${rule.id} (${rule.symbol} ${rule.timeframe}) ${indicator.toUpperCase()}(${period})=${currentValue.toFixed(2)}, previous=${previousValue.toFixed(2)}, candles=${candles.length}, levels=${rule.levels}, mode=${rule.mode}, cooldown=${rule.cooldown_sec}, firstCheck=${isFirstCheck}`);

            // On first check, don't send notifications - just initialize the state
            // This prevents spam notifications when alerts are first created
            const ruleTriggers = isFirstCheck ? [] : this.checkCrossings(
                rule,
                currentValue,
                previousValue,
                Date.now(),
                indicator
            );
            if (ruleTriggers.length === 0 && !isFirstCheck) {
                console.log(`Rule ${rule.id}: no trigger this run`);
            } else if (isFirstCheck) {
                console.log(`Rule ${rule.id}: first check, skipping triggers to prevent spam`);
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
     * Calculate Williams %R (Williams Percent Range)
     * Formula: %R = ((Highest High - Close) / (Highest High - Lowest Low)) × -100
     * Values range from -100 to 0
     */
    calculateWilliams(candles: any[], period: number): number[] {
        if (candles.length < period) {
        return [];
    }

        const highs = candles.map(c => c.high);
        const lows = candles.map(c => c.low);
        const closes = candles.map(c => c.close);
        const williamsValues: number[] = [];

        // Calculate Williams %R starting from index period - 1
        for (let i = period - 1; i < candles.length; i++) {
            // Get high and low values for the period
            const periodHighs = highs.slice(i - period + 1, i + 1);
            const periodLows = lows.slice(i - period + 1, i + 1);
            const close = closes[i];

            const highestHigh = Math.max(...periodHighs);
            const lowestLow = Math.min(...periodLows);

            let williams: number;
            if (highestHigh === lowestLow) {
                // Avoid division by zero - use -50 as neutral value
                williams = -50.0;
            } else {
                williams = ((highestHigh - close) / (highestHigh - lowestLow)) * -100.0;
                williams = Math.max(-100.0, Math.min(0.0, williams));
            }

            williamsValues.push(williams);
        }

        return williamsValues;
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
            // One-way crossing logic:
            // - Lower level (levelsWithNull[0]) triggers only on downward crossing (cross_down) - when value falls below the level
            // - Upper level (levelsWithNull[1]) triggers only on upward crossing (cross_up) - when value rises above the level
            // Use levelsWithNull if available (new format with null), otherwise fallback to levels (old format)
            const levelsArray = rule.levelsWithNull || (rule.levels.length === 1 ? [rule.levels[0], null] : rule.levels.length >= 2 ? [rule.levels[0], rule.levels[1]] : [null, null]);
            
            const lowerLevel = levelsArray[0];
            const upperLevel = levelsArray[1];
            
            // Lower level: downward crossing only (e.g., from 21 to 19 for level 20)
            if (lowerLevel !== null && lowerLevel !== undefined) {
                if (this.checkCrossDown(currentValue, previousValue, lowerLevel)) {
                    triggers.push({
                        ruleId: rule.id,
                        userId: rule.user_id,
                        symbol: rule.symbol,
                        indicatorValue: currentValue,
                        indicator: indicator,
                        rsi: currentValue,  // Keep for backward compatibility
                        level: lowerLevel,
                        type: 'cross_down',
                        timestamp: timestamp,
                        message: `${indicatorName} crossed level ${lowerLevel} downward (${currentValue.toFixed(1)})`
                    });
                }
            }
            
            // Upper level: upward crossing only (e.g., from 79 to 81 for level 80)
            if (upperLevel !== null && upperLevel !== undefined) {
                if (this.checkCrossUp(currentValue, previousValue, upperLevel)) {
                    triggers.push({
                        ruleId: rule.id,
                        userId: rule.user_id,
                        symbol: rule.symbol,
                        indicatorValue: currentValue,
                        indicator: indicator,
                        rsi: currentValue,  // Keep for backward compatibility
                        level: upperLevel,
                        type: 'cross_up',
                        timestamp: timestamp,
                        message: `${indicatorName} crossed level ${upperLevel} upward (${currentValue.toFixed(1)})`
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
     * Determine if a single level is upper or lower based on indicator type and value
     * - For RSI/STOCH (0-100 range): >= 50 is upper, < 50 is lower
     * - For Williams %R (-100 to 0 range): >= -50 is upper, < -50 is lower
     */
    isUpperLevel(level: number, indicator: string): boolean {
        const indicatorLower = indicator.toLowerCase();
        if (indicatorLower === 'williams' || indicatorLower === 'wpr') {
            // Williams %R: range -100 to 0, typical levels -80 (lower) and -20 (upper)
            return level >= -50;
        } else {
            // RSI/STOCH: range 0 to 100, typical levels 30 (lower) and 70 (upper)
            return level >= 50;
        }
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
                        const result = await this.checkSymbolTimeframe(symbol, timeframe, rules);
                        results[symbol][timeframe] = result.triggers;
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
