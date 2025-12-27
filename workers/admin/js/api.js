/**
 * API Client for Admin Dashboard
 */

// API Base URL - укажите URL вашего Cloudflare Worker
// Для локального тестирования используйте явный URL worker'а
const API_BASE_URL = 'https://rsi-workers.vovan4ikukraine.workers.dev';

// Альтернативный вариант: использовать текущий origin (если frontend на том же домене)
// const API_BASE_URL = window.location.origin.replace(/\/$/, '');

class AdminAPI {
    constructor() {
        this.apiKey = localStorage.getItem('admin_api_key') || '';
        this.updateStatusIndicator();
    }

    setApiKey(key) {
        this.apiKey = key;
        localStorage.setItem('admin_api_key', key);
        this.updateStatusIndicator();
    }

    getApiKey() {
        return this.apiKey;
    }

    updateStatusIndicator() {
        const indicator = document.getElementById('apiKeyStatus');
        if (indicator) {
            indicator.className = 'status-indicator ' + (this.apiKey ? 'connected' : 'disconnected');
        }
    }

    async request(endpoint, options = {}) {
        if (!this.apiKey) {
            throw new Error('API key not set');
        }

        const url = `${API_BASE_URL}${endpoint}`;
        const headers = {
            'Content-Type': 'application/json',
            'X-Admin-API-Key': this.apiKey,
            ...options.headers,
        };

        const response = await fetch(url, {
            ...options,
            headers,
        });

        if (!response.ok) {
            const error = await response.json().catch(() => ({ error: 'Unknown error' }));
            throw new Error(error.error || `HTTP ${response.status}`);
        }

        return response.json();
    }

    async getStats() {
        return this.request('/admin/stats');
    }

    async getUsers(limit = 50, offset = 0) {
        return this.request(`/admin/users?limit=${limit}&offset=${offset}`);
    }

    async getProviders() {
        return this.request('/admin/providers');
    }

    async updateProviders(config) {
        return this.request('/admin/providers', {
            method: 'PUT',
            body: JSON.stringify(config),
        });
    }
}

// Global API instance
const adminAPI = new AdminAPI();

