package com.indicharts.app

import android.content.Context
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * Service for loading widget data in background without launching Activity
 */
object WidgetDataService {
    private const val TAG = "WidgetDataService"
    private const val YAHOO_ENDPOINT = "https://rsi-workers.vovan4ikukraine.workers.dev"
    private const val PREF_PENDING_REQUEST_ID = "pending_request_id"
    private val httpClient = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(10, TimeUnit.SECONDS)
        .build()

    /**
     * Loads widget data in background
     */
    suspend fun refreshWidgetData(context: Context, requestId: Long): Boolean {
        return withContext(Dispatchers.IO) {
            try {
                val prefs = context.getSharedPreferences("rsi_widget_data", Context.MODE_PRIVATE)

                fun isCurrentRequest(): Boolean {
                    val pending = prefs.getLong(PREF_PENDING_REQUEST_ID, requestId)
                    return pending == requestId
                }

                if (!isCurrentRequest()) {
                    Log.d(TAG, "Request $requestId cancelled before start")
                    return@withContext false
                }

                // Load watchlist from SharedPreferences
                val watchlistJson = prefs.getString("watchlist_symbols", "[]") ?: "[]"
                val watchlist = parseWatchlist(watchlistJson)

                // Limit watchlist size for widget (max 30 symbols to prevent performance issues)
                val limitedWatchlist = if (watchlist.size > 30) {
                    Log.w(TAG, "Watchlist has ${watchlist.size} symbols, limiting to 30 for widget")
                    watchlist.take(30)
                } else {
                    watchlist
                }

                // If watchlist is empty, clear old data and return
                if (limitedWatchlist.isEmpty()) {
                    Log.d(TAG, "Watchlist is empty, clearing old widget data")
                    // Clear old watchlist_data to prevent widget from showing stale data
                    prefs.edit()
                        .putString("watchlist_data", "[]")
                        .putString("watchlist_symbols", "[]")
                        .commit()
                    return@withContext false
                }

                if (!isCurrentRequest()) {
                    Log.d(TAG, "Request $requestId cancelled after watchlist load")
                    return@withContext false
                }

                Log.d(TAG, "Using watchlist with ${limitedWatchlist.size} symbols (limited from ${watchlist.size}): $limitedWatchlist")

                // Load widget settings
                val timeframe = prefs.getString("timeframe", "15m") ?: "15m"
                val indicator = prefs.getString("widget_indicator", "rsi") ?: "rsi"
                
                // CRITICAL: Read period for CURRENT indicator from watchlist/home settings
                // Priority: watchlist_${indicator}_period > home_${indicator}_period > defaults
                // DO NOT use rsi_widget_period as it may contain stale value from previous indicator
                val watchlistPeriodKey = "watchlist_${indicator}_period"
                val homePeriodKey = "home_${indicator}_period"
                val watchlistPeriod = prefs.getInt(watchlistPeriodKey, -1)
                val homePeriod = prefs.getInt(homePeriodKey, -1)
                val widgetPeriod = prefs.getInt("rsi_widget_period", -1) // Only for logging
                
                // CRITICAL: Always prioritize watchlist_${indicator}_period and home_${indicator}_period
                // Ignore rsi_widget_period as it may contain stale value from previous indicator
                val rsiPeriod = when {
                    watchlistPeriod != -1 -> watchlistPeriod
                    homePeriod != -1 -> homePeriod
                    else -> when (indicator.lowercase()) {
                        "stoch" -> 6
                        "wpr", "williams" -> 14
                        else -> 14
                    }
                }
                
                // For STOCH, ALWAYS read %D period from watchlist/home settings (even if widget_indicator_params exists)
                // This ensures that changes in watchlist STOCH %D period are reflected in widget
                // Also include slowPeriod and smoothPeriod to match Watchlist Slow Stochastic implementation
                var indicatorParamsJson = prefs.getString("widget_indicator_params", null)
                if (indicator.lowercase() == "stoch") {
                    // Get %D period for STOCH from watchlist/home settings (priority: watchlist > home > default)
                    val stochDPeriod = prefs.getInt("watchlist_stoch_d_period",
                        prefs.getInt("home_stoch_d_period", 6))
                    // Use Slow Stochastic defaults to match Watchlist: slowPeriod=3, smoothPeriod=3
                    indicatorParamsJson = "{\"dPeriod\":$stochDPeriod,\"slowPeriod\":3,\"smoothPeriod\":3}"
                    // Always save the latest value from watchlist/home to widget_indicator_params
                    prefs.edit().putString("widget_indicator_params", indicatorParamsJson).commit()
                }

                Log.d(TAG, "WidgetDataService: Loading data with timeframe: $timeframe, indicator: $indicator")
                Log.d(TAG, "WidgetDataService: Period sources - watchlist_${indicator}_period=$watchlistPeriod, home_${indicator}_period=$homePeriod, rsi_widget_period=$widgetPeriod (IGNORED) -> USING period=$rsiPeriod")
                Log.d(TAG, "WidgetDataService: STOCH params: $indicatorParamsJson")

                // Load data for each symbol
                val widgetData = mutableListOf<WidgetItem>()

                for (symbol in limitedWatchlist) {
                    if (!isCurrentRequest()) {
                        Log.d(TAG, "Request $requestId cancelled before loading $symbol")
                        return@withContext false
                    }
                    try {
                        Log.d(TAG, "Loading data for symbol: $symbol with timeframe: $timeframe, period: $rsiPeriod, indicator: $indicator")
                        val item = loadSymbolData(symbol, timeframe, rsiPeriod, indicator, indicatorParamsJson)
                        if (item != null) {
                            widgetData.add(item)
                            Log.d(TAG, "Successfully loaded data for $symbol: RSI=${item.rsi}, Price=${item.price}, Chart values=${item.rsiValues.size}")
                        } else {
                            Log.w(TAG, "Failed to load data for $symbol: item is null")
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "Error loading data for $symbol: ${e.message}", e)
                        e.printStackTrace()
                        // Continue loading other symbols
                    }
                }

                Log.d(TAG, "Total loaded ${widgetData.size} items out of ${limitedWatchlist.size} symbols")

                // ALWAYS sort data by indicator value before saving (critical!)
                // For RSI and STOCH: ascending (low to high) - smallest values first
                // For WPR: descending (high to low) - since values are negative, -20 > -80, so higher (less negative) first
                val indicatorLower = indicator.lowercase()
                val shouldSortDescending = indicatorLower == "wpr" || indicatorLower == "williams"
                widgetData.sortWith { a, b ->
                    val valueA = a.indicatorValue
                    val valueB = b.indicatorValue
                    if (shouldSortDescending) {
                        valueB.compareTo(valueA) // Descending for WPR: -20 before -80
                    } else {
                        valueA.compareTo(valueB) // Ascending for RSI/STOCH: 20 before 80
                    }
                }
                Log.d(TAG, "SORTED ${widgetData.size} widget items: ${if (shouldSortDescending) "DESCENDING" else "ASCENDING"} for indicator '$indicator'")
                if (widgetData.isNotEmpty()) {
                    Log.d(TAG, "First item: ${widgetData.first().symbol}=${widgetData.first().indicatorValue}, Last item: ${widgetData.last().symbol}=${widgetData.last().indicatorValue}")
                }

                // Save updated data (use commit for synchronous save)
                val jsonData = widgetDataToJson(widgetData)
                val editor = prefs.edit()
                if (!isCurrentRequest()) {
                    Log.d(TAG, "Request $requestId cancelled before saving data")
                    return@withContext false
                }
                editor.putString("watchlist_data", jsonData)
                editor.putString("timeframe", timeframe)
                editor.putInt("rsi_period", rsiPeriod)
                editor.putInt("rsi_widget_period", rsiPeriod) // Also save to widget period for consistency
                editor.putString("widget_indicator", indicator)
                if (indicatorParamsJson != null) {
                    editor.putString("widget_indicator_params", indicatorParamsJson)
                } else {
                    editor.remove("widget_indicator_params")
                }
                val saved = editor.commit() // commit() executes synchronously

                if (saved) {
                    // Verify that data was actually saved
                    val verifyJson = if (isCurrentRequest()) prefs.getString("watchlist_data", null) else null
                    if (verifyJson == jsonData) {
                        Log.d(TAG, "Widget data refreshed and saved: ${widgetData.size} items, JSON length: ${jsonData.length}")
                        Log.d(TAG, "Saved timeframe: $timeframe, period: $rsiPeriod")
                        Log.d(TAG, "Data verified in SharedPreferences")
                        return@withContext true
                    } else {
                        Log.e(TAG, "Data verification failed: saved data doesn't match")
                        return@withContext false
                    }
                } else {
                    Log.e(TAG, "Failed to save widget data")
                    return@withContext false
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error refreshing widget data: ${e.message}", e)
                return@withContext false
            }
        }
    }

    private fun candlesLimitForTimeframe(timeframe: String): Int {
        return when (timeframe.lowercase()) {
            "4h" -> 500
            "1d" -> 730
            else -> 100
        }
    }

    /**
     * Loads data for one symbol
     * Note: Currently calculates RSI only. For other indicators (like Stochastic),
     * the data is calculated in Flutter and passed via watchlistData.
     * This method is used only when widget refreshes data itself.
     */
    private suspend fun loadSymbolData(symbol: String, timeframe: String, rsiPeriod: Int, indicator: String = "rsi", indicatorParams: String? = null): WidgetItem? {
        return withContext(Dispatchers.IO) {
            try {
                // Load candles
                val limit = candlesLimitForTimeframe(timeframe)
                val url = "$YAHOO_ENDPOINT/yf/candles?symbol=$symbol&tf=$timeframe&limit=$limit"
                Log.d(TAG, "Fetching candles from: $url")
                val request = Request.Builder()
                    .url(url)
                    .header("accept", "application/json")
                    .build()

                val response = httpClient.newCall(request).execute()
                if (!response.isSuccessful) {
                    Log.e(TAG, "Failed to load candles for $symbol: HTTP ${response.code}, body: ${response.body?.string()}")
                    return@withContext null
                }

                val responseBody = response.body?.string() ?: return@withContext null
                Log.d(TAG, "Received response for $symbol: ${responseBody.length} bytes")
                val candles = parseCandles(responseBody)

                if (candles.isEmpty()) {
                    Log.w(TAG, "No candles parsed for $symbol")
                    return@withContext null
                }

                Log.d(TAG, "Parsed ${candles.size} candles for $symbol")

                // Calculate indicator based on type
                val closes = candles.map { it.close }
                val highs = candles.map { it.high }
                val lows = candles.map { it.low }
                
                // Parse indicatorParams for STOCH (dPeriod, slowPeriod, smoothPeriod)
                // Match Watchlist implementation: Slow Stochastic with slowPeriod=3, smoothPeriod=3 by default
                var dPeriod = 6 // Default for STOCH (matches Watchlist)
                var slowPeriod = 3 // Default Slow Stochastic smoothing (matches Watchlist)
                var smoothPeriod = 3 // Default %D smoothing (matches Watchlist)
                if (indicator.lowercase() == "stoch" && indicatorParams != null) {
                    try {
                        val paramsJson = org.json.JSONObject(indicatorParams)
                        if (paramsJson.has("dPeriod")) {
                            dPeriod = paramsJson.getInt("dPeriod")
                        }
                        if (paramsJson.has("slowPeriod")) {
                            slowPeriod = paramsJson.getInt("slowPeriod")
                        }
                        if (paramsJson.has("smoothPeriod")) {
                            smoothPeriod = paramsJson.getInt("smoothPeriod")
                        }
                    } catch (e: Exception) {
                        Log.w(TAG, "Failed to parse indicatorParams for $symbol: ${e.message}, using defaults")
                    }
                }
                
                val indicatorValues = when (indicator.lowercase()) {
                    "wpr", "williams" -> {
                        Log.d(TAG, "Calculating Williams %R for $symbol: ${closes.size} candles, period=$rsiPeriod")
                        calculateWilliams(highs, lows, closes, rsiPeriod)
                    }
                    "stoch" -> {
                        Log.d(TAG, "Calculating Stochastic for $symbol: ${closes.size} candles, kPeriod=$rsiPeriod, dPeriod=$dPeriod, slowPeriod=$slowPeriod, smoothPeriod=$smoothPeriod")
                        calculateStochastic(highs, lows, closes, rsiPeriod, dPeriod, slowPeriod, smoothPeriod)
                    }
                    else -> {
                        Log.d(TAG, "Calculating RSI for $symbol: ${closes.size} closes, period=$rsiPeriod")
                        calculateRSI(closes, rsiPeriod)
                    }
                }

                if (indicatorValues.isEmpty()) {
                    Log.w(TAG, "$indicator calculation returned empty for $symbol (need at least ${rsiPeriod + 1} candles)")
                    return@withContext null
                }

                val currentValue = indicatorValues.last()
                val currentPrice = closes.last()
                // Take last 20 values for chart
                val chartValues = if (indicatorValues.size > 20) {
                    indicatorValues.subList(indicatorValues.size - 20, indicatorValues.size)
                } else {
                    indicatorValues
                }

                Log.d(TAG, "Calculated $indicator for $symbol: current=$currentValue, chart values=${chartValues.size}, first=${chartValues.firstOrNull()}, last=${chartValues.lastOrNull()}")

                return@withContext WidgetItem(
                    symbol = symbol,
                    rsi = currentValue, // Keep for backward compatibility
                    indicatorValue = currentValue,
                    indicator = indicator,
                    price = currentPrice,
                    rsiValues = chartValues
                )
            } catch (e: Exception) {
                Log.e(TAG, "Error loading symbol data for $symbol: ${e.message}", e)
                return@withContext null
            }
        }
    }

    /**
     * Parses watchlist from JSON
     */
    private fun parseWatchlist(json: String): List<String> {
        return try {
            val array = JSONArray(json)
            (0 until array.length()).map { array.getString(it) }
        } catch (e: Exception) {
            Log.e(TAG, "Error parsing watchlist: ${e.message}")
            emptyList()
        }
    }

    /**
     * Parses candles from JSON response
     */
    private fun parseCandles(json: String): List<Candle> {
        return try {
            val array = JSONArray(json)
            (0 until array.length()).map { index ->
                val obj = array.getJSONObject(index)
                Candle(
                    open = obj.getDouble("open"),
                    high = obj.getDouble("high"),
                    low = obj.getDouble("low"),
                    close = obj.getDouble("close"),
                    volume = obj.getLong("volume"),
                    timestamp = obj.getLong("timestamp")
                )
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error parsing candles: ${e.message}")
            emptyList()
        }
    }

    /**
     * Calculates Stochastic Oscillator (%K and %D)
     * Matches Watchlist implementation: Slow Stochastic with optional smoothing
     * Returns %D values (smoothed %K with additional %D smoothing), matching Flutter implementation
     */
    private fun calculateStochastic(highs: List<Double>, lows: List<Double>, closes: List<Double>, kPeriod: Int, dPeriod: Int, slowPeriod: Int = 3, smoothPeriod: Int = 3): List<Double> {
        val useSlowStochastic = slowPeriod > 1
        val useSmoothPeriod = smoothPeriod > 1
        
        // Calculate minimum data required
        val minDataRequired = if (useSlowStochastic) {
            kPeriod + slowPeriod + dPeriod - 2 + if (useSmoothPeriod) (smoothPeriod - 1) else 0
        } else {
            kPeriod + dPeriod - 1 + if (useSmoothPeriod) (smoothPeriod - 1) else 0
        }
        
        if (closes.size < minDataRequired) {
            return emptyList()
        }

        // Step 1: Calculate raw %K values (Fast Stochastic %K)
        val rawKValues = mutableListOf<Double>()

        for (i in (kPeriod - 1) until closes.size) {
            val periodHighs = highs.subList(i - kPeriod + 1, i + 1)
            val periodLows = lows.subList(i - kPeriod + 1, i + 1)
            val close = closes[i]

            val highestHigh = periodHighs.maxOrNull() ?: 0.0
            val lowestLow = periodLows.minOrNull() ?: 0.0

            val k = if (highestHigh == lowestLow) {
                50.0 // Neutral value to avoid division by zero
            } else {
                ((close - lowestLow) / (highestHigh - lowestLow)) * 100.0
            }
            rawKValues.add(k.coerceIn(0.0, 100.0))
        }

        // Step 2: Apply Slow Stochastic smoothing if needed
        val kValues = if (useSlowStochastic) {
            if (rawKValues.size < slowPeriod) {
                return emptyList()
            }
            val smoothedK = mutableListOf<Double>()
            for (i in (slowPeriod - 1) until rawKValues.size) {
                val periodKValues = rawKValues.subList(i - slowPeriod + 1, i + 1)
                val smoothed = periodKValues.average()
                smoothedK.add(smoothed.coerceIn(0.0, 100.0))
            }
            smoothedK
        } else {
            rawKValues
        }

        // Step 3: Calculate %D as SMA of (smoothed) %K
        if (kValues.size < dPeriod) {
            return emptyList()
        }

        val dValues = mutableListOf<Double>()
        for (i in (dPeriod - 1) until kValues.size) {
            val periodKValues = kValues.subList(i - dPeriod + 1, i + 1)
            val d = periodKValues.average()
            dValues.add(d.coerceIn(0.0, 100.0))
        }

        // Step 4: Apply additional smoothing to %D if smoothPeriod is provided
        if (useSmoothPeriod) {
            if (dValues.size < smoothPeriod) {
                return emptyList()
            }
            val smoothedD = mutableListOf<Double>()
            for (i in (smoothPeriod - 1) until dValues.size) {
                val periodDValues = dValues.subList(i - smoothPeriod + 1, i + 1)
                val smoothed = periodDValues.average()
                smoothedD.add(smoothed.coerceIn(0.0, 100.0))
            }
            return smoothedD
        }

        return dValues
    }

    /**
     * Calculates Williams %R
     */
    private fun calculateWilliams(highs: List<Double>, lows: List<Double>, closes: List<Double>, period: Int): List<Double> {
        if (closes.size < period) {
            return emptyList()
        }

        val williamsValues = mutableListOf<Double>()

        for (i in (period - 1) until closes.size) {
            val periodHighs = highs.subList(i - period + 1, i + 1)
            val periodLows = lows.subList(i - period + 1, i + 1)
            val close = closes[i]

            val highestHigh = periodHighs.maxOrNull() ?: 0.0
            val lowestLow = periodLows.minOrNull() ?: 0.0

            val williams = if (highestHigh == lowestLow) {
                -50.0 // Neutral value to avoid division by zero
            } else {
                ((highestHigh - close) / (highestHigh - lowestLow)) * -100.0
            }
            williamsValues.add(williams.coerceIn(-100.0, 0.0))
        }

        return williamsValues
    }

    /**
     * Calculates RSI using Wilder's algorithm
     */
    private fun calculateRSI(closes: List<Double>, period: Int): List<Double> {
        if (closes.size < period + 1) {
            return emptyList()
        }

        val rsiValues = mutableListOf<Double>()

        // Calculate initial average values
        var gain = 0.0
        var loss = 0.0
        for (i in 1..period) {
            val change = closes[i] - closes[i - 1]
            if (change > 0) {
                gain += change
            } else {
                loss -= change
            }
        }

        var au = gain / period // Average Up
        var ad = loss / period // Average Down

        // Incremental calculation for remaining points
        for (i in (period + 1) until closes.size) {
            val change = closes[i] - closes[i - 1]
            val u = if (change > 0) change else 0.0
            val d = if (change < 0) -change else 0.0

            // Update using Wilder's formula
            au = (au * (period - 1) + u) / period
            ad = (ad * (period - 1) + d) / period

            // Calculate RSI
            val rsi = if (ad == 0.0) {
                100.0
            } else {
                val rs = au / ad
                100 - (100 / (1 + rs))
            }
            rsiValues.add(rsi.coerceIn(0.0, 100.0))
        }

        return rsiValues
    }

    /**
     * Converts widget data to JSON
     */
    private fun widgetDataToJson(items: List<WidgetItem>): String {
        val array = JSONArray()
        for (item in items) {
            val obj = JSONObject()
            obj.put("symbol", item.symbol)
            obj.put("rsi", item.rsi) // Keep for backward compatibility
            obj.put("indicatorValue", item.indicatorValue)
            obj.put("indicator", item.indicator)
            obj.put("price", item.price)
            val rsiArray = JSONArray()
            for (rsiValue in item.rsiValues) {
                rsiArray.put(rsiValue)
            }
            obj.put("rsiValues", rsiArray)
            obj.put("indicatorValues", rsiArray) // Also add as indicatorValues for consistency
            array.put(obj)
        }
        return array.toString()
    }

    /**
     * Candle data
     */
    private data class Candle(
        val open: Double,
        val high: Double,
        val low: Double,
        val close: Double,
        val volume: Long,
        val timestamp: Long
    )

    /**
     * Widget item
     */
    data class WidgetItem(
        val symbol: String,
        val rsi: Double, // Keep for backward compatibility
        val indicatorValue: Double, // New field for generic indicator value
        val indicator: String = "rsi", // Indicator type: "rsi", "stoch", etc.
        val price: Double,
        val rsiValues: List<Double> // Keep for backward compatibility
    )
}

