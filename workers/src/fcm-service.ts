export interface FcmMessage {
    to: string;
    data: {
        alert_id: string;
        symbol: string;
        rsi: string;
        level: string;
        type: string;
        message: string;
        timestamp: string;
    };
    notification?: {
        title: string;
        body: string;
        sound?: string;
    };
}

export class FcmService {
    constructor(
        private serverKey: string,
        private endpoint: string,
        private db?: D1Database
    ) { }

    /**
     * Send alert via FCM
     */
    async sendAlert(trigger: any): Promise<void> {
        try {
            // Get user FCM tokens
            const tokens = await this.getUserFcmTokens(trigger.userId, this.db);

            if (tokens.length === 0) {
                console.log(`No FCM tokens found for user ${trigger.userId}`);
                return;
            }

            // Send to each device
            for (const token of tokens) {
                await this.sendToDevice(token, trigger);
            }

            console.log(`Alert sent to ${tokens.length} devices for user ${trigger.userId}`);
        } catch (error) {
            console.error('Error sending FCM alert:', error);
        }
    }

    /**
     * Send message to device
     */
    async sendToDevice(token: string, trigger: any): Promise<void> {
        const message: FcmMessage = {
            to: token,
            data: {
                alert_id: trigger.ruleId.toString(),
                symbol: trigger.symbol,
                rsi: trigger.rsi.toString(),
                level: trigger.level.toString(),
                type: trigger.type,
                message: trigger.message,
                timestamp: trigger.timestamp.toString(),
            },
            notification: {
                title: `RSI Alert: ${trigger.symbol}`,
                body: trigger.message,
                sound: 'default',
            }
        };

        try {
            const response = await fetch(this.endpoint, {
                method: 'POST',
                headers: {
                    'Authorization': `key=${this.serverKey}`,
                    'Content-Type': 'application/json',
                },
                body: JSON.stringify(message),
            });

            if (!response.ok) {
                const errorText = await response.text();
                console.error(`FCM error: ${response.status} - ${errorText}`);

                // If token is invalid, remove it
                if (response.status === 400 || response.status === 401) {
                    await this.removeInvalidToken(token, this.db);
                }
            } else {
                console.log(`FCM message sent successfully to ${token.substring(0, 10)}...`);
            }
        } catch (error) {
            console.error('Error sending FCM message:', error);
        }
    }

    /**
     * Get user FCM tokens
     */
    async getUserFcmTokens(userId: string, db?: D1Database): Promise<string[]> {
        if (!db) {
            console.warn('Database not provided for getUserFcmTokens');
            return [];
        }

        try {
            const result = await db.prepare(`
                SELECT fcm_token FROM device 
                WHERE user_id = ? AND fcm_token IS NOT NULL
            `).bind(userId).all();

            return (result.results as any[]).map(row => row.fcm_token).filter(Boolean);
        } catch (error) {
            console.error('Error fetching FCM tokens:', error);
            return [];
        }
    }

    /**
     * Remove invalid token
     */
    async removeInvalidToken(token: string, db?: D1Database): Promise<void> {
        if (!db) {
            console.warn('Database not provided for removeInvalidToken');
            return;
        }

        try {
            await db.prepare(`
                DELETE FROM device WHERE fcm_token = ?
            `).bind(token).run();

            console.log(`Removed invalid token: ${token.substring(0, 10)}...`);
        } catch (error) {
            console.error('Error removing invalid token:', error);
        }
    }

    /**
     * Send test message
     */
    async sendTestMessage(token: string, message: string): Promise<boolean> {
        try {
            const response = await fetch(this.endpoint, {
                method: 'POST',
                headers: {
                    'Authorization': `key=${this.serverKey}`,
                    'Content-Type': 'application/json',
                },
                body: JSON.stringify({
                    to: token,
                    notification: {
                        title: 'RSI Widget Test',
                        body: message,
                    },
                    data: {
                        type: 'test',
                        message: message,
                    }
                }),
            });

            return response.ok;
        } catch (error) {
            console.error('Error sending test message:', error);
            return false;
        }
    }

    /**
     * Send connection notification
     */
    async sendConnectionNotification(userId: string, connected: boolean): Promise<void> {
        const tokens = await this.getUserFcmTokens(userId);

        for (const token of tokens) {
            await this.sendToDevice(token, {
                userId,
                symbol: 'SYSTEM',
                rsi: 0,
                level: 0,
                type: 'connection',
                message: connected ? 'Connected to server' : 'Disconnected from server',
                timestamp: Date.now(),
            });
        }
    }

    /**
     * Send error notification
     */
    async sendErrorNotification(userId: string, error: string): Promise<void> {
        const tokens = await this.getUserFcmTokens(userId);

        for (const token of tokens) {
            await this.sendToDevice(token, {
                userId,
                symbol: 'SYSTEM',
                rsi: 0,
                level: 0,
                type: 'error',
                message: `Error: ${error}`,
                timestamp: Date.now(),
            });
        }
    }
}
