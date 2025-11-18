# Cache Testing Guide

## How to Verify Cache is Working Correctly

### Method 1: Via Browser (DevTools)

1. Open DevTools (F12) in your browser
2. Go to the **Network** tab
3. Open URL:
   ```
   https://rsi-workers.vovan4ikukraine.workers.dev/yf/candles?symbol=AAPL&tf=15m&debug=true
   ```
4. Check the response:
   - **First request**: `meta.source = "yahoo"` (data loaded from Yahoo)
   - **Second request** (within cache TTL): `meta.source = "cache"` (data from cache)

### Method 2: Via HTTP Headers

1. Open DevTools → Network
2. Make a request:
   ```
   https://rsi-workers.vovan4ikukraine.workers.dev/yf/candles?symbol=AAPL&tf=15m
   ```
3. Check response headers:
   - **First request**: `X-Data-Source: yahoo`
   - **Second request** (within cache TTL): `X-Data-Source: cache`

### Method 3: From Two Devices Simultaneously

1. **On first device**: Open the app and select a symbol (e.g., AAPL)
2. **On second device**: Open the app and select the same symbol (AAPL)
3. **Check logs in Cloudflare Dashboard**:
   - First request: `❌ CACHE MISS` → `💾 Cached`
   - Second request: `✅ CACHE HIT`

### Method 4: Via curl (Command Line)

```bash
# First request (should be yahoo)
curl -I "https://rsi-workers.vovan4ikukraine.workers.dev/yf/candles?symbol=AAPL&tf=15m"
# Check header: X-Data-Source: yahoo

# Second request immediately after first (should be cache)
curl -I "https://rsi-workers.vovan4ikukraine.workers.dev/yf/candles?symbol=AAPL&tf=15m"
# Check header: X-Data-Source: cache
```

### Method 5: With debug Parameter (JSON Response)

```bash
# First request
curl "https://rsi-workers.vovan4ikukraine.workers.dev/yf/candles?symbol=AAPL&tf=15m&debug=true"
# Response: {"data": [...], "meta": {"source": "yahoo", ...}}

# Second request (within cache TTL)
curl "https://rsi-workers.vovan4ikukraine.workers.dev/yf/candles?symbol=AAPL&tf=15m&debug=true"
# Response: {"data": [...], "meta": {"source": "cache", ...}}
```

## What to Verify:

1. ✅ **First request** always goes to Yahoo Finance
2. ✅ **Second request** (within cache TTL) gets data from cache
3. ✅ **After cache expires** next request goes to Yahoo again
4. ✅ **Two devices** with the same symbol use the same cache

## Logs in Cloudflare Dashboard

In logs you will see:
- `✅ CACHE HIT` - data from cache
- `❌ CACHE MISS` - data loaded from Yahoo
- `💾 Cached` - data saved to cache

## Important:

- Cache is valid for **60 seconds**
- Cache is shared across all users (key: `candles:SYMBOL:TIMEFRAME`)
- If two devices request the same symbol, the second will get data from cache
