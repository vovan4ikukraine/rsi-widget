package com.example.rsi_widget

import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.example.rsi_widget/widget"
    private val TAG = "MainActivity"
    private var methodChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        
        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "updateWidget" -> {
                    try {
                        val watchlistData = call.argument<String>("watchlistData")
                        val timeframe = call.argument<String>("timeframe") ?: "15m"
                        val rsiPeriod = call.argument<Int>("rsiPeriod") ?: 14
                        val indicator = call.argument<String>("indicator") ?: "rsi"
                        val indicatorParams = call.argument<String>("indicatorParams")
                        val watchlistSymbols = call.argument<List<String>>("watchlistSymbols")
                        
                        Log.d(TAG, "Updating widget with ${watchlistData?.length ?: 0} chars, timeframe: $timeframe, period: $rsiPeriod, indicator: $indicator, params: $indicatorParams")
                        
                        // Save data to SharedPreferences
                        // Use commit() instead of apply() to ensure synchronous save
                        // This prevents WidgetDataService from reading stale widget_indicator value
                        val prefs = getSharedPreferences("rsi_widget_data", Context.MODE_PRIVATE)
                        prefs.edit().apply {
                            putString("watchlist_data", watchlistData)
                            putString("timeframe", timeframe)
                            putInt("rsi_period", rsiPeriod)
                            putInt("rsi_widget_period", rsiPeriod) // Also save to widget period for consistency
                            putString("widget_indicator", indicator) // CRITICAL: must be saved synchronously
                            if (indicatorParams != null) {
                                putString("widget_indicator_params", indicatorParams)
                            } else {
                                remove("widget_indicator_params")
                            }
                            watchlistSymbols?.let {
                                putString("watchlist_symbols", JSONArray(it).toString())
                            }
                            putBoolean("is_loading", false)
                            commit() // Use commit() for synchronous save to prevent race condition
                        }
                        
                        // Send broadcast to update widget
                        val intent = Intent(RSIWidgetProvider.ACTION_UPDATE_WIDGET)
                        sendBroadcast(intent)
                        
                        result.success(true)
                    } catch (e: Exception) {
                        Log.e(TAG, "Error updating widget", e)
                        result.error("ERROR", e.message, null)
                    }
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
        
        // Handle Intent on launch (if app opens from widget)
        // Widget now updates in background, but if user clicks widget item,
        // app will open with selected symbol
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        
        // Handle widget click - open app with selected symbol
        val symbol = intent.getStringExtra("symbol")
        if (symbol != null) {
            Log.d(TAG, "Opening app with symbol: $symbol")
            // Flutter will handle this through initialSymbol in HomeScreen
        }
    }
}
