/**
 * Providers page functionality
 */

document.addEventListener('DOMContentLoaded', () => {
    const apiKeyInput = document.getElementById('apiKeyInput');
    const connectBtn = document.getElementById('connectBtn');
    const loading = document.getElementById('loading');
    const error = document.getElementById('error');
    const providersContent = document.getElementById('providersContent');
    const saveBtn = document.getElementById('saveProvidersBtn');
    const resetBtn = document.getElementById('resetProvidersBtn');

    // Load saved API key
    if (adminAPI.getApiKey()) {
        apiKeyInput.value = adminAPI.getApiKey();
        adminAPI.updateStatusIndicator();
        loadProviders();
    }

    connectBtn.addEventListener('click', () => {
        const apiKey = apiKeyInput.value.trim();
        if (!apiKey) {
            alert('Please enter an API key');
            return;
        }

        adminAPI.setApiKey(apiKey);
        loadProviders();
    });

    saveBtn.addEventListener('click', async () => {
        const config = {
            stocks: {
                primary: document.getElementById('stocks-primary').value,
                fallback: document.getElementById('stocks-fallback').value || null,
            },
            crypto: {
                primary: document.getElementById('crypto-primary').value,
                fallback: document.getElementById('crypto-fallback').value || null,
            },
            forex: {
                primary: document.getElementById('forex-primary').value,
                fallback: document.getElementById('forex-fallback').value || null,
            },
        };

        try {
            loading.style.display = 'block';
            const result = await adminAPI.updateProviders(config);
            loading.style.display = 'none';
            
            // Show stub message
            alert('Provider configuration update is not yet implemented. This is a stub endpoint.\n\nConfiguration received:\n' + JSON.stringify(config, null, 2));
            
            // Reload to show current state
            loadProviders();
        } catch (err) {
            loading.style.display = 'none';
            alert(`Error: ${err.message}`);
            console.error('Provider update error:', err);
        }
    });

    resetBtn.addEventListener('click', () => {
        if (confirm('Reset all changes?')) {
            loadProviders();
        }
    });

    async function loadProviders() {
        loading.style.display = 'block';
        error.style.display = 'none';
        providersContent.style.display = 'none';

        try {
            const config = await adminAPI.getProviders();

            // Update stocks
            document.getElementById('stocks-primary').value = config.stocks?.primary || 'YF_PROTO';
            document.getElementById('stocks-fallback').value = config.stocks?.fallback || '';
            updateStatusBadge('stocks-status', config.stocks?.status || 'online');

            // Update crypto
            document.getElementById('crypto-primary').value = config.crypto?.primary || 'YF_PROTO';
            document.getElementById('crypto-fallback').value = config.crypto?.fallback || '';
            updateStatusBadge('crypto-status', config.crypto?.status || 'online');

            // Update forex
            document.getElementById('forex-primary').value = config.forex?.primary || 'YF_PROTO';
            document.getElementById('forex-fallback').value = config.forex?.fallback || '';
            updateStatusBadge('forex-status', config.forex?.status || 'online');

            loading.style.display = 'none';
            providersContent.style.display = 'block';
        } catch (err) {
            loading.style.display = 'none';
            error.style.display = 'block';
            error.textContent = `Error: ${err.message}`;
            console.error('Providers load error:', err);
        }
    }

    function updateStatusBadge(elementId, status) {
        const badge = document.getElementById(elementId);
        if (!badge) return;

        badge.className = 'status-badge status-' + status;
        badge.textContent = status.charAt(0).toUpperCase() + status.slice(1);
    }
});







