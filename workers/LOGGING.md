# Logging in Cloudflare Worker

## How Logging Works

In production (`ENVIRONMENT = "production"`), logging is optimized:

### ✅ What is ALWAYS logged (even in production):
- **Errors** (`Logger.error`) - critical issues
- **Warnings** (`Logger.warn`) - important events

### ❌ What is NOT logged in production:
- **Debug logs** (`Logger.debug`) - detailed debugging information
- **Info logs** (`Logger.info`) - informational messages
- **Cache operations** - caching details (cache hit/miss/save)

## Log Levels

```typescript
Logger.debug('Detailed debugging information', env);  // Dev only
Logger.info('Informational message', env);            // Dev only
Logger.warn('Warning', env);                          // Always
Logger.error('Error', error, env);                    // Always
```

## Special Methods for Cache

```typescript
Logger.cacheHit(symbol, timeframe, count, env);   // Dev only
Logger.cacheMiss(symbol, timeframe, env);          // Dev only
Logger.cacheSave(symbol, timeframe, count, env);   // Dev only
```

## Environment Configuration

In `wrangler.toml`:
```toml
[vars]
ENVIRONMENT = "production"  # or "development"
```

## Performance Impact

### In Production:
- **Minimal load**: only errors and warnings are logged
- **Fast operation**: no unnecessary log write operations
- **Resource savings**: fewer entries in Cloudflare Logs

### In Development:
- **Full logging**: all events are logged
- **Easy debugging**: all cache operations are visible

## Examples

### In Production:
```
[ERROR] Error fetching candles: Network timeout
[WARN] Cache miss for AAPL 15m
```

### In Development:
```
[DEBUG] Processing request for AAPL 15m
[INFO] Running scheduled RSI check for 5 active rule(s)...
[2025-11-17T22:30:00.000Z] ✅ CACHE HIT for AAPL 15m (100 candles)
[2025-11-17T22:30:01.000Z] ❌ CACHE MISS for TSLA 1h, fetching from Yahoo Finance...
[2025-11-17T22:30:02.000Z] 💾 Cached 500 candles for TSLA 1h
```

## Recommendations

1. **In production** keep `ENVIRONMENT = "production"` - this minimizes logging
2. **For debugging** temporarily set `ENVIRONMENT = "development"` or remove the variable
3. **Errors are always logged** - this is important for monitoring issues
4. **Cache operations** are not logged in production, but can be checked via HTTP headers (`X-Data-Source`)

## Checking Cache Without Logs

Even without logs, you can check caching via:
- HTTP headers: `X-Data-Source: cache` or `X-Data-Source: yahoo`
- Debug parameter: `?debug=true` in URL (returns metadata in JSON)
