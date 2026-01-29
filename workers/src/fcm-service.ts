export interface FcmV1Message {
    message: {
        token: string;
        notification?: {
            title: string;
            body: string;
        };
        data?: {
            [key: string]: string;
        };
        android?: {
            priority: 'normal' | 'high';
            collapse_key?: string;
        };
        apns?: {
            headers: {
                'apns-priority': string;
                'apns-collapse-id'?: string;
            };
        };
    };
}

interface ServiceAccount {
    type: string;
    project_id: string;
    private_key_id: string;
    private_key: string;
    client_email: string;
    client_id: string;
    auth_uri: string;
    token_uri: string;
}

export class FcmService {
    private accessToken: string | null = null;
    private tokenExpiry: number = 0;
    private serviceAccount: ServiceAccount | null = null;

    constructor(
        private serviceAccountJson: string,
        private projectId: string,
        private kv?: KVNamespace,
        private db?: D1Database
    ) {
        try {
            this.serviceAccount = JSON.parse(this.serviceAccountJson);
        } catch (error) {
            console.error('Failed to parse service account JSON:', error);
        }
    }

    /**
     * Base64 URL encode
     */
    private base64UrlEncode(data: string): string {
        return btoa(data)
            .replace(/\+/g, '-')
            .replace(/\//g, '_')
            .replace(/=/g, '');
    }

    /**
     * Create JWT for OAuth2
     * Note: Cloudflare Workers has limitations with RS256 signing
     * This uses a workaround by converting PEM to JWK format
     */
    private async createJWT(): Promise<string> {
        if (!this.serviceAccount) {
            throw new Error('Service account not initialized');
        }

        const now = Math.floor(Date.now() / 1000);
        const expiry = now + 3600; // 1 hour

        const header = {
            alg: 'RS256',
            typ: 'JWT'
        };

        const claim = {
            iss: this.serviceAccount.client_email,
            scope: 'https://www.googleapis.com/auth/firebase.messaging',
            aud: this.serviceAccount.token_uri,
            exp: expiry,
            iat: now
        };

        const encodedHeader = this.base64UrlEncode(JSON.stringify(header));
        const encodedClaim = this.base64UrlEncode(JSON.stringify(claim));
        const signatureInput = `${encodedHeader}.${encodedClaim}`;

        // Parse PEM private key
        const privateKeyPem = this.serviceAccount.private_key
            .replace(/-----BEGIN PRIVATE KEY-----/g, '')
            .replace(/-----END PRIVATE KEY-----/g, '')
            .replace(/\s/g, '');

        const privateKeyDer = Uint8Array.from(atob(privateKeyPem), c => c.charCodeAt(0));

        try {
            // Try to import as PKCS8
            const key = await crypto.subtle.importKey(
                'pkcs8',
                privateKeyDer.buffer,
                {
                    name: 'RSASSA-PKCS1-v1_5',
                    hash: 'SHA-256',
                },
                false,
                ['sign']
            );

            // Sign
            const signature = await crypto.subtle.sign(
                {
                    name: 'RSASSA-PKCS1-v1_5',
                },
                key,
                new TextEncoder().encode(signatureInput)
            );

            const encodedSignature = this.base64UrlEncode(
                String.fromCharCode(...new Uint8Array(signature))
            );

            return `${signatureInput}.${encodedSignature}`;
        } catch (error) {
            console.error('Error creating JWT:', error);
            throw new Error(`Failed to create JWT: ${error instanceof Error ? error.message : String(error)}`);
        }
    }

    /**
     * Get OAuth2 access token from Google
     */
    private async getAccessTokenFromGoogle(): Promise<{ access_token: string; expires_in: number }> {
        if (!this.serviceAccount) {
            throw new Error('Service account not initialized');
        }

        const jwt = await this.createJWT();

        const response = await fetch(this.serviceAccount.token_uri, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/x-www-form-urlencoded',
            },
            body: new URLSearchParams({
                grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
                assertion: jwt
            })
        });

        if (!response.ok) {
            const errorText = await response.text();
            throw new Error(`Failed to get access token: ${response.status} - ${errorText}`);
        }

        const data = await response.json() as { access_token: string; expires_in?: number };
        return {
            access_token: data.access_token,
            expires_in: data.expires_in || 3600
        };
    }

    /**
     * Get OAuth2 access token (cached or fresh)
     */
    private async getAccessToken(): Promise<string> {
        // Check cache in KV first
        if (this.kv) {
            try {
                const cached = await this.kv.get('fcm_access_token', { type: 'json' }) as { token: string; expiry: number } | null;
                if (cached && cached.expiry > Date.now() + 60000) { // Refresh 1 min before expiry
                    this.accessToken = cached.token;
                    this.tokenExpiry = cached.expiry;
                    console.log('Using cached FCM access token');
                    if (this.accessToken) {
                    return this.accessToken;
                    }
                }
            } catch (error) {
                console.warn('Failed to read from KV cache:', error);
            }
        }

        // Check in-memory cache
        if (this.accessToken && Date.now() < this.tokenExpiry - 60000) {
            return this.accessToken;
        }

        // Get new token
        console.log('Refreshing FCM access token...');
        const tokenData = await this.getAccessTokenFromGoogle();
        this.accessToken = tokenData.access_token;
        this.tokenExpiry = Date.now() + (tokenData.expires_in * 1000);

        // Cache in KV
        if (this.kv) {
            try {
                await this.kv.put('fcm_access_token', JSON.stringify({
                    token: this.accessToken,
                    expiry: this.tokenExpiry
                }));
            } catch (error) {
                console.warn('Failed to cache token in KV:', error);
            }
        }

        console.log(`FCM access token refreshed, expires in ${tokenData.expires_in}s`);
        return this.accessToken;
    }

    /**
     * Send alert via FCM V1 API
     * Only sends if notification is recent (not older than maxAgeMinutes)
     */
    async sendAlert(trigger: any, maxAgeMinutes: number = 10): Promise<void> {
        try {
            // Check if notification is still relevant (not too old)
            const now = Date.now();
            const triggerAge = now - trigger.timestamp;
            const maxAgeMs = maxAgeMinutes * 60 * 1000;

            if (triggerAge > maxAgeMs) {
                console.log(`Skipping stale notification for rule ${trigger.ruleId}: age=${Math.round(triggerAge / 1000)}s (max=${maxAgeMinutes * 60}s)`);
                return;
            }

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

            console.log(`Alert sent to ${tokens.length} devices for user ${trigger.userId} (age=${Math.round(triggerAge / 1000)}s)`);
        } catch (error) {
            console.error('Error sending FCM alert:', error);
        }
    }

    /**
     * Send message to device using FCM V1 API
     */
    async sendToDevice(token: string, trigger: any): Promise<void> {
        if (!this.projectId || this.projectId.trim() === '') {
            console.error('FCM_PROJECT_ID is empty or not set!');
            return;
        }

        if (!token || token.trim() === '') {
            console.error('FCM token is empty!');
            return;
        }

        const accessToken = await this.getAccessToken();
        const endpoint = `https://fcm.googleapis.com/v1/projects/${this.projectId}/messages:send`;

        // Use collapse_key to replace old notifications with new ones for the same rule
        // This prevents accumulation of stale notifications when device is offline
        const collapseKey = `alert_${trigger.ruleId}`;

        // Determine notification title based on source
        const isWatchlistAlert = trigger.source === 'watchlist';
        const timeframeSuffix = trigger.timeframe ? ` (${trigger.timeframe})` : '';
        const title = isWatchlistAlert 
            ? `Watchlist: ${trigger.symbol}${timeframeSuffix}`
            : `${trigger.symbol}${timeframeSuffix}`;

        const message: FcmV1Message = {
            message: {
                token: token,
                notification: {
                    title: title,
                    body: trigger.message,
                },
                data: {
                    alert_id: trigger.ruleId.toString(),
                    symbol: trigger.symbol,
                    rsi: trigger.rsi.toString(),
                    level: trigger.level.toString(),
                    type: trigger.type,
                    message: trigger.message,
                    timestamp: trigger.timestamp.toString(),
                    indicator: trigger.indicator || 'rsi',
                    timeframe: trigger.timeframe || '',
                    source: trigger.source || 'custom',
                    isWatchlistAlert: isWatchlistAlert ? 'true' : 'false',
                },
                android: {
                    priority: 'high',
                    collapse_key: collapseKey,
                },
                apns: {
                    headers: {
                        'apns-priority': '10',
                        'apns-collapse-id': collapseKey,
                    },
                },
            }
        };

        try {
            const response = await fetch(endpoint, {
                method: 'POST',
                headers: {
                    'Authorization': `Bearer ${accessToken}`,
                    'Content-Type': 'application/json',
                },
                body: JSON.stringify(message),
            });

            if (!response.ok) {
                const errorText = await response.text();
                console.error(`FCM V1 error: ${response.status} - ${errorText}`);

                // If token is invalid (401), try to refresh
                if (response.status === 401) {
                    console.log('Access token expired, refreshing...');
                    this.accessToken = null; // Force refresh
                    this.tokenExpiry = 0;
                    const newToken = await this.getAccessToken();

                    // Retry once with new token
                    const retryResponse = await fetch(endpoint, {
                        method: 'POST',
                        headers: {
                            'Authorization': `Bearer ${newToken}`,
                            'Content-Type': 'application/json',
                        },
                        body: JSON.stringify(message),
                    });

                    if (!retryResponse.ok) {
                        const retryErrorText = await retryResponse.text();
                        console.error(`FCM V1 retry error: ${retryResponse.status} - ${retryErrorText}`);
                    } else {
                        console.log(`FCM V1 message sent successfully after token refresh`);
                    }
                    return;
                }

                // If token is invalid (404), remove it
                if (response.status === 404) {
                    try {
                        const errorData = JSON.parse(errorText);
                        if (errorData.error?.status === 'NOT_FOUND' || errorData.error?.message?.includes('UNREGISTERED')) {
                            await this.removeInvalidToken(token, this.db);
                        }
                    } catch (e) {
                        // Ignore parse errors
                    }
                }
            } else {
                console.log(`FCM V1 message sent successfully to ${token.substring(0, 10)}...`);
            }
        } catch (error) {
            console.error('Error sending FCM V1 message:', error);
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
     * Remove invalid token and clean up anonymous user alerts if no other devices
     */
    async removeInvalidToken(token: string, db?: D1Database): Promise<void> {
        if (!db) {
            console.warn('Database not provided for removeInvalidToken');
            return;
        }

        try {
            // First, get the user_id for this token
            const device = await db.prepare(`
                SELECT user_id FROM device WHERE fcm_token = ?
            `).bind(token).first<{ user_id: string }>();

            // Delete the device with invalid token
            await db.prepare(`
                DELETE FROM device WHERE fcm_token = ?
            `).bind(token).run();

            console.log(`Removed invalid token: ${token.substring(0, 10)}...`);

            // If this was an anonymous user, check if they have other devices
            if (device?.user_id && this.isAnonymousUser(device.user_id)) {
                const otherDevices = await db.prepare(`
                    SELECT COUNT(*) as count FROM device WHERE user_id = ?
                `).bind(device.user_id).first<{ count: number }>();

                // If no other devices, clean up alerts for this anonymous user
                // (they likely uninstalled the app)
                if (!otherDevices || otherDevices.count === 0) {
                    await this.cleanupAnonymousUserAlerts(device.user_id, db);
                }
            }
        } catch (error) {
            console.error('Error removing invalid token:', error);
        }
    }

    /**
     * Check if user is anonymous (userId starts with 'user_')
     */
    private isAnonymousUser(userId: string): boolean {
        return !!userId && userId.startsWith('user_');
    }

    /**
     * Clean up all alerts for an anonymous user (only alerts, not watchlist or preferences)
     */
    async cleanupAnonymousUserAlerts(userId: string, db: D1Database): Promise<void> {
        try {
            console.log(`Cleaning up alerts for anonymous user: ${userId}`);

            // Get all alert IDs for this user
            const alerts = await db.prepare(`
                SELECT id FROM alert_rule WHERE user_id = ?
            `).bind(userId).all();

            const alertIds = (alerts.results as any[]).map(a => a.id);

            if (alertIds.length === 0) {
                console.log(`No alerts to clean up for user: ${userId}`);
                return;
            }

            // Delete alert events
            await db.prepare(`
                DELETE FROM alert_event WHERE rule_id IN (SELECT id FROM alert_rule WHERE user_id = ?)
            `).bind(userId).run();

            // Delete alert states
            await db.prepare(`
                DELETE FROM alert_state WHERE rule_id IN (SELECT id FROM alert_rule WHERE user_id = ?)
            `).bind(userId).run();

            // Delete alert rules
            await db.prepare(`
                DELETE FROM alert_rule WHERE user_id = ?
            `).bind(userId).run();

            console.log(`Cleaned up ${alertIds.length} alerts for anonymous user: ${userId}`);
        } catch (error) {
            console.error(`Error cleaning up alerts for anonymous user ${userId}:`, error);
        }
    }
}
