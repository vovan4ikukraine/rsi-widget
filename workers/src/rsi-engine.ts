import { YahooService } from './yahoo-service';

export interface AlertRule {
    id: number;
    user_id: string;
    symbol: string;
    timeframe: string;
    rsi_period: number;
    levels: number[];
    mode: string;
    hysteresis: number;
    cooldown_sec: number;
    active: number;
    created_at: number;
}

export interface AlertState {
    rule_id: number;
    last_rsi?: number;
    last_bar_ts?: number;
    last_fire_ts?: number;
    last_side?: string;
    last_au?: number;
    last_ad?: number;
}

export interface AlertTrigger {
    ruleId: number;
    userId: string;
    symbol: string;
    rsi: number;
    level: number;
    type: 'cross_up' | 'cross_down' | 'enter_zone' | 'exit_zone';
    timestamp: number;
    message: string;
}

export class RsiEngine {
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

        return result.results.map((row: any) => ({
            ...row,
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
            // Get candles
            const candles = await this.yahooService.getCandles(symbol, timeframe, {
                limit: 1000
            });

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
     * Check specific rule
     */
    async checkRule(rule: AlertRule, candles: any[]): Promise<AlertTrigger[]> {
        const triggers: AlertTrigger[] = [];

        try {
            // Get rule state
            const state = await this.getAlertState(rule.id);

            // Calculate RSI
            const rsiData = this.calculateRsi(candles, rule.rsi_period);

            if (rsiData.length < 2) {
                return triggers;
            }

            const currentRsi = rsiData[rsiData.length - 1];
            const previousRsi = state.last_rsi || rsiData[rsiData.length - 2];

            // Check crossings
            const ruleTriggers = this.checkCrossings(
                rule,
                currentRsi,
                previousRsi,
                Date.now()
            );

            if (ruleTriggers.length > 0) {
                // Check cooldown
                const canFire = this.checkCooldown(rule, state);

                if (canFire) {
                    // Save state
                    await this.updateAlertState(rule.id, {
                        last_rsi: currentRsi,
                        last_bar_ts: candles[candles.length - 1].timestamp,
                        last_fire_ts: Date.now(),
                        last_side: this.getRsiZone(currentRsi, rule.levels),
                    });

                    // Save events
                    for (const trigger of ruleTriggers) {
                        await this.saveAlertEvent(rule.id, trigger);
                    }

                    triggers.push(...ruleTriggers);
                }
            } else {
                // Update only RSI without triggering
                await this.updateAlertState(rule.id, {
                    last_rsi: currentRsi,
                    last_bar_ts: candles[candles.length - 1].timestamp,
                });
            }

        } catch (error) {
            console.error(`Error checking rule ${rule.id}:`, error);
        }

        return triggers;
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
     * Check level crossings
     */
    checkCrossings(
        rule: AlertRule,
        currentRsi: number,
        previousRsi: number,
        timestamp: number
    ): AlertTrigger[] {
        const triggers: AlertTrigger[] = [];

        if (rule.mode === 'cross') {
            for (const level of rule.levels) {
                // Upward crossing
                if (this.checkCrossUp(currentRsi, previousRsi, level, rule.hysteresis)) {
                    triggers.push({
                        ruleId: rule.id,
                        userId: rule.user_id,
                        symbol: rule.symbol,
                        rsi: currentRsi,
                        level: level,
                        type: 'cross_up',
                        timestamp: timestamp,
                        message: `RSI crossed level ${level} upward (${currentRsi.toFixed(1)})`
                    });
                }

                // Downward crossing
                if (this.checkCrossDown(currentRsi, previousRsi, level, rule.hysteresis)) {
                    triggers.push({
                        ruleId: rule.id,
                        userId: rule.user_id,
                        symbol: rule.symbol,
                        rsi: currentRsi,
                        level: level,
                        type: 'cross_down',
                        timestamp: timestamp,
                        message: `RSI crossed level ${level} downward (${currentRsi.toFixed(1)})`
                    });
                }
            }
        } else if (rule.mode === 'enter' && rule.levels.length >= 2) {
            if (this.checkEnterZone(
                currentRsi,
                previousRsi,
                rule.levels[0],
                rule.levels[1],
                rule.hysteresis
            )) {
                triggers.push({
                    ruleId: rule.id,
                    userId: rule.user_id,
                    symbol: rule.symbol,
                    rsi: currentRsi,
                    level: rule.levels[1],
                    type: 'enter_zone',
                    timestamp: timestamp,
                    message: `RSI entered zone ${rule.levels[0]}-${rule.levels[1]} (${currentRsi.toFixed(1)})`
                });
            }
        } else if (rule.mode === 'exit' && rule.levels.length >= 2) {
            if (this.checkExitZone(
                currentRsi,
                previousRsi,
                rule.levels[0],
                rule.levels[1],
                rule.hysteresis
            )) {
                triggers.push({
                    ruleId: rule.id,
                    userId: rule.user_id,
                    symbol: rule.symbol,
                    rsi: currentRsi,
                    level: rule.levels[1],
                    type: 'exit_zone',
                    timestamp: timestamp,
                    message: `RSI exited zone ${rule.levels[0]}-${rule.levels[1]} (${currentRsi.toFixed(1)})`
                });
            }
        }

        return triggers;
    }

    /**
     * Check upward crossing
     */
    checkCrossUp(currentRsi: number, previousRsi: number, level: number, hysteresis: number): boolean {
        return previousRsi <= (level - hysteresis) && currentRsi > (level + hysteresis);
    }

    /**
     * Check downward crossing
     */
    checkCrossDown(currentRsi: number, previousRsi: number, level: number, hysteresis: number): boolean {
        return previousRsi >= (level + hysteresis) && currentRsi < (level - hysteresis);
    }

    /**
     * Check zone entry
     */
    checkEnterZone(
        currentRsi: number,
        previousRsi: number,
        lowerLevel: number,
        upperLevel: number,
        hysteresis: number
    ): boolean {
        const wasOutside = previousRsi < (lowerLevel - hysteresis) ||
            previousRsi > (upperLevel + hysteresis);
        const isInside = currentRsi >= (lowerLevel + hysteresis) &&
            currentRsi <= (upperLevel - hysteresis);

        return wasOutside && isInside;
    }

    /**
     * Check zone exit
     */
    checkExitZone(
        currentRsi: number,
        previousRsi: number,
        lowerLevel: number,
        upperLevel: number,
        hysteresis: number
    ): boolean {
        const wasInside = previousRsi >= (lowerLevel - hysteresis) &&
            previousRsi <= (upperLevel + hysteresis);
        const isOutside = currentRsi < (lowerLevel + hysteresis) ||
            currentRsi > (upperLevel - hysteresis);

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
     * Determine RSI zone
     */
    getRsiZone(rsi: number, levels: number[]): string {
        if (levels.length === 0) return 'between';

        const lowerLevel = levels[0];
        const upperLevel = levels.length > 1 ? levels[1] : 100;

        if (rsi < lowerLevel) return 'below';
        if (rsi > upperLevel) return 'above';
        return 'between';
    }

    /**
     * Get alert state
     */
    async getAlertState(ruleId: number): Promise<AlertState> {
        const result = await this.db.prepare(`
          SELECT * FROM alert_state WHERE rule_id = ?
        `).bind(ruleId).first();

        return (result as unknown as AlertState) || {
            rule_id: ruleId,
            last_rsi: undefined,
            last_bar_ts: undefined,
            last_fire_ts: undefined,
            last_side: undefined,
        };
    }

    /**
     * Update alert state
     */
    async updateAlertState(ruleId: number, updates: Partial<AlertState>): Promise<void> {
        const values = Object.values(updates);
        values.push(ruleId);

        await this.db.prepare(`
          INSERT OR REPLACE INTO alert_state (rule_id, ${Object.keys(updates).join(', ')})
          VALUES (?, ${Object.keys(updates).map(() => '?').join(', ')})
        `).bind(ruleId, ...values).run();
    }

    /**
     * Save alert event
     */
    async saveAlertEvent(ruleId: number, trigger: AlertTrigger): Promise<void> {
        await this.db.prepare(`
      INSERT INTO alert_event (rule_id, ts, rsi, level, side, bar_ts, symbol)
      VALUES (?, ?, ?, ?, ?, ?, ?)
    `).bind(
            ruleId,
            trigger.timestamp,
            trigger.rsi,
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
