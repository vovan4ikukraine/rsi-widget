package com.example.rsi_widget

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * Сервис для загрузки данных виджета в фоне без запуска Activity
 */
object WidgetDataService {
    private const val TAG = "WidgetDataService"
    private const val YAHOO_ENDPOINT = "https://rsi-workers.vovan4ikukraine.workers.dev"
    private val httpClient = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(10, TimeUnit.SECONDS)
        .build()

    /**
     * Загружает данные для виджета в фоне
     */
    suspend fun refreshWidgetData(context: Context): Boolean {
        return withContext(Dispatchers.IO) {
            try {
                val prefs = context.getSharedPreferences("rsi_widget_data", Context.MODE_PRIVATE)
                
                // Загружаем watchlist из SharedPreferences
                var watchlistJson = prefs.getString("watchlist_symbols", "[]") ?: "[]"
                var watchlist = parseWatchlist(watchlistJson)
                
                // Если watchlist пуст, пытаемся извлечь символы из существующих данных
                if (watchlist.isEmpty()) {
                    Log.d(TAG, "Watchlist symbols is empty, trying to extract from existing data")
                    val existingDataJson = prefs.getString("watchlist_data", "[]") ?: "[]"
                    if (existingDataJson.isNotEmpty() && existingDataJson != "[]") {
                        try {
                            val existingArray = JSONArray(existingDataJson)
                            watchlist = mutableListOf()
                            for (i in 0 until existingArray.length()) {
                                val item = existingArray.getJSONObject(i)
                                val symbol = item.getString("symbol")
                                (watchlist as MutableList).add(symbol)
                            }
                            // Сохраняем извлеченный watchlist для будущего использования
                            val extractedJson = JSONArray(watchlist).toString()
                            prefs.edit().putString("watchlist_symbols", extractedJson).commit()
                            Log.d(TAG, "Extracted ${watchlist.size} symbols from existing data")
                        } catch (e: Exception) {
                            Log.e(TAG, "Error extracting symbols from existing data: ${e.message}")
                            return@withContext false
                        }
                    }
                }
                
                if (watchlist.isEmpty()) {
                    Log.d(TAG, "Watchlist is still empty after extraction attempt")
                    return@withContext false
                }
                
                Log.d(TAG, "Using watchlist with ${watchlist.size} symbols: $watchlist")
                
                // Загружаем настройки виджета
                val timeframe = prefs.getString("timeframe", "15m") ?: "15m"
                // Используем период из виджета, если установлен, иначе из общих настроек
                val rsiPeriod = prefs.getInt("rsi_widget_period", 
                    prefs.getInt("rsi_period", 14))
                
                Log.d(TAG, "Loading data with timeframe: $timeframe, period: $rsiPeriod")
                
                // Загружаем данные для каждого символа
                val widgetData = mutableListOf<WidgetItem>()
                
                for (symbol in watchlist) {
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
                        // Продолжаем загрузку других символов
                    }
                }
                
                Log.d(TAG, "Total loaded ${widgetData.size} items out of ${watchlist.size} symbols")
                
                // Сохраняем обновленные данные (используем commit для синхронного сохранения)
                val jsonData = widgetDataToJson(widgetData)
                val editor = prefs.edit()
                editor.putString("watchlist_data", jsonData)
                editor.putString("timeframe", timeframe)
                editor.putInt("rsi_period", rsiPeriod)
                val saved = editor.commit() // commit() выполняется синхронно
                
                if (saved) {
                    // Проверяем, что данные действительно сохранились
                    val verifyJson = prefs.getString("watchlist_data", null)
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
    
    /**
     * Загружает данные для одного символа
     */
    private suspend fun loadSymbolData(symbol: String, timeframe: String, rsiPeriod: Int): WidgetItem? {
        return withContext(Dispatchers.IO) {
            try {
                // Загружаем свечи
                val url = "$YAHOO_ENDPOINT/yf/candles?symbol=$symbol&tf=$timeframe&limit=100"
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
                
                // Рассчитываем RSI
                val closes = candles.map { it.close }
                Log.d(TAG, "Calculating RSI for $symbol: ${closes.size} closes, period=$rsiPeriod")
                val rsiValues = calculateRSI(closes, rsiPeriod)
                
                if (rsiValues.isEmpty()) {
                    Log.w(TAG, "RSI calculation returned empty for $symbol (need at least ${rsiPeriod + 1} closes)")
                    return@withContext null
                }
                
                val currentRsi = rsiValues.last()
                val currentPrice = closes.last()
                val previousPrice = if (closes.size > 1) closes[closes.size - 2] else currentPrice
                val change = currentPrice - previousPrice
                
                // Берем последние 20 значений для графика
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
                    change = change,
                    rsiValues = chartValues
                )
            } catch (e: Exception) {
                Log.e(TAG, "Error loading symbol data for $symbol: ${e.message}", e)
                return@withContext null
            }
        }
    }
    
    /**
     * Парсит watchlist из JSON
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
     * Парсит свечи из JSON ответа
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
     * Рассчитывает RSI по алгоритму Wilder
     */
    private fun calculateRSI(closes: List<Double>, period: Int): List<Double> {
        if (closes.size < period + 1) {
            return emptyList()
        }
        
        val rsiValues = mutableListOf<Double>()
        
        // Расчет первых средних значений
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
        
        // Инкрементальный расчет для остальных точек
        for (i in (period + 1) until closes.size) {
            val change = closes[i] - closes[i - 1]
            val u = if (change > 0) change else 0.0
            val d = if (change < 0) -change else 0.0
            
            // Обновление по формуле Wilder
            au = (au * (period - 1) + u) / period
            ad = (ad * (period - 1) + d) / period
            
            // Расчет RSI
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
     * Преобразует данные виджета в JSON
     */
    private fun widgetDataToJson(items: List<WidgetItem>): String {
        val array = JSONArray()
        for (item in items) {
            val obj = JSONObject()
            obj.put("symbol", item.symbol)
            obj.put("rsi", item.rsi)
            obj.put("price", item.price)
            obj.put("change", item.change)
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
     * Данные свечи
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
     * Элемент виджета
     */
    data class WidgetItem(
        val symbol: String,
        val rsi: Double,
        val price: Double,
        val change: Double,
        val rsiValues: List<Double>
    )
}

