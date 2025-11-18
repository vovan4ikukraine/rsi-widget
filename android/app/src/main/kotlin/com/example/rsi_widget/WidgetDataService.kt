package com.example.rsi_widget

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

                // Limit watchlist size for widget (max 50 symbols to prevent performance issues)
                val limitedWatchlist = if (watchlist.size > 50) {
                    Log.w(TAG, "Watchlist has ${watchlist.size} symbols, limiting to 50 for widget")
                    watchlist.take(50)
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
                // Use period from widget if set, otherwise from general settings
                val rsiPeriod = prefs.getInt("rsi_widget_period",
                    prefs.getInt("rsi_period", 14))

                Log.d(TAG, "Loading data with timeframe: $timeframe, period: $rsiPeriod")

                // Load data for each symbol
                val widgetData = mutableListOf<WidgetItem>()

                for (symbol in limitedWatchlist) {
                    if (!isCurrentRequest()) {
                        Log.d(TAG, "Request $requestId cancelled before loading $symbol")
                        return@withContext false
                    }
                    try {
                        Log.d(TAG, "Loading data for symbol: $symbol with timeframe: $timeframe, period: $rsiPeriod")
                        val item = loadSymbolData(symbol, timeframe, rsiPeriod)
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
     */
    private suspend fun loadSymbolData(symbol: String, timeframe: String, rsiPeriod: Int): WidgetItem? {
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

                // Calculate RSI
                val closes = candles.map { it.close }
                Log.d(TAG, "Calculating RSI for $symbol: ${closes.size} closes, period=$rsiPeriod")
                val rsiValues = calculateRSI(closes, rsiPeriod)

                if (rsiValues.isEmpty()) {
                    Log.w(TAG, "RSI calculation returned empty for $symbol (need at least ${rsiPeriod + 1} closes)")
                    return@withContext null
                }

                val currentRsi = rsiValues.last()
                val currentPrice = closes.last()
                // Take last 20 values for chart
                val chartValues = if (rsiValues.size > 20) {
                    rsiValues.subList(rsiValues.size - 20, rsiValues.size)
                } else {
                    rsiValues
                }

                Log.d(TAG, "Calculated RSI for $symbol: current=$currentRsi, chart values=${chartValues.size}, first=${chartValues.firstOrNull()}, last=${chartValues.lastOrNull()}")

                return@withContext WidgetItem(
                    symbol = symbol,
                    rsi = currentRsi,
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
            obj.put("rsi", item.rsi)
            obj.put("price", item.price)
            val rsiArray = JSONArray()
            for (rsiValue in item.rsiValues) {
                rsiArray.put(rsiValue)
            }
            obj.put("rsiValues", rsiArray)
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
        val rsi: Double,
        val price: Double,
        val rsiValues: List<Double>
    )
}

