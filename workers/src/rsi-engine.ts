import { DataProviderService } from './data-provider-service';

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
    alert_on_close?: boolean;  // true = only closed candles, false = crossing (incl. forming)
    source?: string;  // 'watchlist' or 'custom' - for notification differentiation
}

export interface AlertState {
    rule_id: number;
    last_indicator_value?: number;  // Universal: last calculated indicator value
    indicator_state?: string;       // JSON: state for incremental calculation
    last_bar_ts?: number;
    last_fire_ts?: number;
    last_fire_ts_lower?: number;    // Lower level last fire ts (cross mode, per-level cooldown)
    last_fire_ts_upper?: number;    // Upper level last fire ts (cross mode, per-level cooldown)
    last_fire_bar_ts?: number;      // Bar timestamp when we last fired (zone modes; fallback for cross)
    last_fire_bar_ts_lower?: number;  // Lower level last fired bar ts (cross mode, per-level)
    last_fire_bar_ts_upper?: number;  // Upper level last fired bar ts (cross mode, per-level)
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
    timeframe?: string;      // Timeframe (e.g., '15m', '1h')
    source?: string;         // 'watchlist' or 'custom' - for notification differentiation
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

/** Timeframe duration in milliseconds (for excluding forming candle). */
function getTimeframeMs(tf: string): number {
    const m: Record<string, number> = {
        '1m': 60 * 1000,
        '5m': 5 * 60 * 1000,
        '15m': 15 * 60 * 1000,
        '30m': 30 * 60 * 1000,
        '1h': 60 * 60 * 1000,
        '4h': 4 * 60 * 60 * 1000,
        '1d': 24 * 60 * 60 * 1000,
    };
    return m[tf] ?? 60 * 60 * 1000;
}

export class IndicatorEngine {
    constructor(
        private db: D1Database,
        private dataProviderService: DataProviderService
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
                created_at: row.created_at || Date.now(),
                alert_on_close: row.alert_on_close === 1 || row.alert_on_close === true,
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
            // Get candles - use DataProviderService (handles cache, Binance for crypto, Yahoo fallback)
            let candles: any[] = [];

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

            // Check cache first
            const cached = await this.dataProviderService.getCachedCandles(symbol, timeframe);
            if (cached && cached.candles.length > 0) {
                candles = cached.candles;
                cacheHit = true;
                console.log(`RSI Engine: Using cached candles from D1 for ${symbol} ${timeframe} (${candles.length} candles, provider=${cached.provider})`);
            }

            // If no cache or cache miss, fetch from provider (Binance for crypto, Yahoo otherwise)
            if (candles.length === 0) {
                try {
                    const result = await this.dataProviderService.getCandles(symbol, timeframe, {
                        limit: candleLimit
                    });
                    candles = result.candles;
                    console.log(`RSI Engine: Fetched and cached ${candles.length} candles (limit=${candleLimit}, period=${maxPeriod}, provider=${result.provider}) in D1 for ${symbol} ${timeframe}`);
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

            // Build closed-only set for "alert on close" rules. Others use full candles (incl. forming).
            const tfMs = getTimeframeMs(timeframe);
            const lastTs = candles[candles.length - 1]?.timestamp ?? 0;
            const isForming = lastTs + tfMs > Date.now();
            const candlesClosed = isForming && candles.length > 2
                ? candles.slice(0, -1)
                : candles;
            if (isForming && candlesClosed.length < 2) {
                console.log(`Not enough closed candles for ${symbol} ${timeframe} (dropped forming)`);
                return { triggers, cacheHit };
            }

            const anyCrossing = rules.some((r: any) => !r.alert_on_close);
            const currentLastTimestamp = candlesClosed[candlesClosed.length - 1]?.timestamp;

            // Skip only when ALL rules are "alert on close" and we've already processed this closed candle.
            // If any rule uses crossing (forming), we never skip — process every run.
            if (!anyCrossing && currentLastTimestamp) {
                let allProcessed = true;
                const ruleStates: Array<{ rule: AlertRule; state: any }> = [];
                for (const rule of rules) {
                    const state = await this.getAlertState(rule.id);
                    ruleStates.push({ rule, state });
                    if (state.last_bar_ts !== currentLastTimestamp) {
                        allProcessed = false;
                        break;
                    }
                }
                if (allProcessed) {
                    const indicatorValuesLog: string[] = [];
                    for (const { rule, state } of ruleStates) {
                        const ind = rule.indicator || 'rsi';
                        const per = rule.period || rule.rsi_period || 14;
                        const v = state.last_indicator_value ?? state.last_rsi ?? 'N/A';
                        indicatorValuesLog.push(`Rule ${rule.id}: ${ind.toUpperCase()}(${per})=${v}`);
                    }
                    console.log(`RSI Engine: Skipping ${symbol} ${timeframe} - last closed candle already processed (ts: ${currentLastTimestamp})`);
                    if (indicatorValuesLog.length > 0) {
                        console.log(`RSI Engine: Current values: ${indicatorValuesLog.join(', ')}`);
                    }
                    return { triggers, cacheHit };
                }
            }

            for (const rule of rules) {
                try {
                    const useClosed = !!(rule as any).alert_on_close;
                    const candleSet = useClosed ? candlesClosed : candles;
                    const ruleTriggers = await this.checkRule(rule, candleSet);
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
                const currentBarTs = candles[candles.length - 1].timestamp;

                // When alert_on_close is false: one fire per candle per LEVEL (lower/upper independent)
                const useFormingCandle = !(rule as any).alert_on_close;
                const isCrossMode = rule.mode === 'cross';

                // Filter triggers: each level can fire only once per candle (cross mode)
                // Zone mode: one fire per candle for the whole rule (use last_fire_bar_ts)
                let allowedTriggers: AlertTrigger[];
                if (useFormingCandle && isCrossMode) {
                    allowedTriggers = ruleTriggers.filter((t) => {
                        const tsLower = state.last_fire_bar_ts_lower ?? state.last_fire_bar_ts;
                        const tsUpper = state.last_fire_bar_ts_upper ?? state.last_fire_bar_ts;
                        const blockedLower = tsLower !== undefined && tsLower === currentBarTs;
                        const blockedUpper = tsUpper !== undefined && tsUpper === currentBarTs;
                        if (t.type === 'cross_down' && blockedLower) {
                            console.log(`Rule ${rule.id}: lower level already fired this candle (bar_ts=${currentBarTs}), skipping`);
                            return false;
                        }
                        if (t.type === 'cross_up' && blockedUpper) {
                            console.log(`Rule ${rule.id}: upper level already fired this candle (bar_ts=${currentBarTs}), skipping`);
                            return false;
                        }
                        return true;
                    });
                } else if (useFormingCandle && !isCrossMode) {
                    const sameCandleAlreadyFired =
                        state.last_fire_bar_ts !== undefined && state.last_fire_bar_ts === currentBarTs;
                    allowedTriggers = sameCandleAlreadyFired ? [] : ruleTriggers;
                    if (sameCandleAlreadyFired) {
                        console.log(`Rule ${rule.id}: same candle already fired (bar_ts=${currentBarTs}), skipping`);
                    }
                } else {
                    allowedTriggers = ruleTriggers;
                }

                // Cooldown: per-level for cross mode, per-rule for zone mode
                if (isCrossMode) {
                    allowedTriggers = allowedTriggers.filter((t) => {
                        const ok = this.checkCooldownForTrigger(rule, state, t);
                        if (!ok) {
                            console.log(`Rule ${rule.id}: ${t.type} level cooldown not passed, skipping`);
                        }
                        return ok;
                    });
                } else {
                    const canFireCooldown = this.checkCooldown(rule, state);
                    if (!canFireCooldown) {
                        allowedTriggers = [];
                        console.log(`Rule ${rule.id}: cooldown not passed, skipping`);
                    }
                }

                const canFire = allowedTriggers.length > 0;
                console.log(`Rule ${rule.id}: allowed triggers -> ${allowedTriggers.length}, canFire -> ${canFire}`);

                if (canFire) {
                    const now = Date.now();
                    stateUpdates.last_fire_ts = now;
                    stateUpdates.last_side = this.getIndicatorZone(currentValue, rule.levels);

                    if (isCrossMode) {
                        const hasLower = allowedTriggers.some((t) => t.type === 'cross_down');
                        const hasUpper = allowedTriggers.some((t) => t.type === 'cross_up');
                        if (hasLower) stateUpdates.last_fire_ts_lower = now;
                        if (hasUpper) stateUpdates.last_fire_ts_upper = now;
                    }

                    if (useFormingCandle && isCrossMode) {
                        const hasLower = allowedTriggers.some((t) => t.type === 'cross_down');
                        const hasUpper = allowedTriggers.some((t) => t.type === 'cross_up');
                        if (hasLower) stateUpdates.last_fire_bar_ts_lower = currentBarTs;
                        if (hasUpper) stateUpdates.last_fire_bar_ts_upper = currentBarTs;
                        stateUpdates.last_fire_bar_ts = currentBarTs;
                    } else if (useFormingCandle) {
                        stateUpdates.last_fire_bar_ts = currentBarTs;
                    }

                    for (const trigger of allowedTriggers) {
                        await this.saveAlertEvent(rule.id, trigger);
                    }
                    triggers.push(...allowedTriggers);
                }
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
     * Supports Slow Stochastic with slowPeriod and smoothPeriod (like Flutter UI)
     */
    calculateStochastic(candles: any[], kPeriod: number, params?: any): Array<{ value: number, state?: any }> {
        // Use defaultParams like Flutter UI does (IndicatorType.stoch.defaultParams)
        // Default: slowPeriod=3, dPeriod=6, smoothPeriod=3
        const defaultParams = {
            slowPeriod: 3,
            dPeriod: 6,
            smoothPeriod: 3
        };
        
        const dPeriod = params?.dPeriod ?? defaultParams.dPeriod;
        const slowPeriod = params?.slowPeriod ?? defaultParams.slowPeriod; // %K smoothing period for Slow Stochastic
        const smoothPeriod = params?.smoothPeriod ?? defaultParams.smoothPeriod; // %D smoothing period
        
        // Use Slow Stochastic if slowPeriod is provided and > 1
        const useSlowStochastic = slowPeriod != null && slowPeriod > 1;
        const slowPeriodValue = slowPeriod ?? 1;
        const minDataRequired = useSlowStochastic
            ? kPeriod + slowPeriodValue + dPeriod - 2
            : kPeriod + dPeriod - 1;

        if (candles.length < minDataRequired) {
            return [];
        }

        const highs = candles.map(c => c.high);
        const lows = candles.map(c => c.low);
        const closes = candles.map(c => c.close);
        
        // Step 1: Calculate raw %K values (Fast Stochastic %K)
        const rawKValues: number[] = [];
        for (let i = kPeriod - 1; i < candles.length; i++) {
            const periodHighs = highs.slice(i - kPeriod + 1, i + 1);
            const periodLows = lows.slice(i - kPeriod + 1, i + 1);

            const highestHigh = Math.max(...periodHighs);
            const lowestLow = Math.min(...periodLows);
            const close = closes[i];

            if (highestHigh === lowestLow) {
                rawKValues.push(50.0);
            } else {
                const k = ((close - lowestLow) / (highestHigh - lowestLow)) * 100.0;
                rawKValues.push(Math.max(0, Math.min(100, k)));
            }
        }

        if (rawKValues.length === 0) {
            return [];
        }

        // Step 2: Apply Slow Stochastic smoothing if needed
        // Smooth %K with SMA(slowPeriod) to get Slow Stochastic %K
        let kValues: number[] = rawKValues;
        if (useSlowStochastic) {
            kValues = [];
            // Calculate SMA of rawKValues with period slowPeriodValue
            for (let i = slowPeriodValue - 1; i < rawKValues.length; i++) {
                const periodValues = rawKValues.slice(i - slowPeriodValue + 1, i + 1);
                const smoothedK = periodValues.reduce((a, b) => a + b, 0) / slowPeriodValue;
                kValues.push(Math.max(0, Math.min(100, smoothedK)));
            }
        }

        if (kValues.length === 0) {
            return [];
        }

        // Step 3: Calculate %D values as SMA of (smoothed) %K
        let dValues: number[] = [];
        for (let i = dPeriod - 1; i < kValues.length; i++) {
            const dPeriodValues = kValues.slice(i - dPeriod + 1, i + 1);
            const d = dPeriodValues.reduce((a, b) => a + b, 0) / dPeriod;
            dValues.push(Math.max(0, Math.min(100, d)));
        }

        // Step 4: Apply additional smoothing to %D if smoothPeriod is provided
        if (smoothPeriod != null && smoothPeriod > 1) {
            const smoothedDValues: number[] = [];
            for (let i = smoothPeriod - 1; i < dValues.length; i++) {
                const periodValues = dValues.slice(i - smoothPeriod + 1, i + 1);
                const smoothedD = periodValues.reduce((a, b) => a + b, 0) / smoothPeriod;
                smoothedDValues.push(Math.max(0, Math.min(100, smoothedD)));
            }
            dValues = smoothedDValues;
        }

        if (dValues.length === 0) {
            return [];
        }

        // Step 5: Build results aligned with candles
        // Calculate offsets to align with candle indices
        const slowOffset = useSlowStochastic ? (slowPeriodValue - 1) : 0;
        const smoothOffset = (smoothPeriod != null && smoothPeriod > 1) ? (smoothPeriod - 1) : 0;
        const firstCandleIndex = kPeriod + slowOffset + dPeriod - 1 + smoothOffset;

        const result: Array<{ value: number, state?: any }> = [];
        for (let i = 0; i < dValues.length; i++) {
            const candleIndex = firstCandleIndex + i;
            if (candleIndex >= candles.length) break;

            // The %K value that corresponds to this %D value
            const kIndexInSmoothed = dPeriod - 1 + smoothOffset + i;
            if (kIndexInSmoothed >= kValues.length) break;

            // For display, use smoothed %K for Slow Stochastic (which is what Yahoo Finance shows)
            // For Fast Stochastic, use raw %K
            const displayK = useSlowStochastic 
                ? kValues[kIndexInSmoothed]  // Use smoothed %K for Slow Stochastic
                : (kIndexInSmoothed < rawKValues.length 
                    ? rawKValues[kIndexInSmoothed] 
                    : kValues[kIndexInSmoothed]);

            result.push({
                value: displayK,  // Use %K as main value (same as Flutter UI)
                state: { k: displayK, d: dValues[i] }  // Store both %K and %D in state
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
                        timeframe: rule.timeframe,
                        source: rule.source || 'custom',
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
                        timeframe: rule.timeframe,
                        source: rule.source || 'custom',
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
                    timeframe: rule.timeframe,
                    source: rule.source || 'custom',
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
                    timeframe: rule.timeframe,
                    source: rule.source || 'custom',
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
     * Check cooldown (zone mode - single last_fire_ts for rule)
     */
    checkCooldown(rule: AlertRule, state: AlertState): boolean {
        if (!state.last_fire_ts) return true;

        const timeSinceLastFire = Date.now() - state.last_fire_ts;
        return timeSinceLastFire >= (rule.cooldown_sec * 1000);
    }

    /**
     * Check cooldown for a specific trigger (cross mode - per level)
     */
    checkCooldownForTrigger(rule: AlertRule, state: AlertState, trigger: AlertTrigger): boolean {
        const ts = trigger.type === 'cross_down'
            ? (state.last_fire_ts_lower ?? state.last_fire_ts)
            : (state.last_fire_ts_upper ?? state.last_fire_ts);
        if (!ts) return true;

        const timeSinceLastFire = Date.now() - ts;
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
            last_fire_ts_lower: undefined,
            last_fire_ts_upper: undefined,
            last_fire_bar_ts: undefined,
            last_fire_bar_ts_lower: undefined,
            last_fire_bar_ts_upper: undefined,
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
