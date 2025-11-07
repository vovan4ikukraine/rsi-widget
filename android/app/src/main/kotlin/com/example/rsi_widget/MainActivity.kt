package com.example.rsi_widget

import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

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
                        
                        Log.d(TAG, "Updating widget with ${watchlistData?.length ?: 0} chars, timeframe: $timeframe, period: $rsiPeriod")
                        
                        // Сохраняем данные в SharedPreferences
                        val prefs = getSharedPreferences("rsi_widget_data", Context.MODE_PRIVATE)
                        prefs.edit().apply {
                            putString("watchlist_data", watchlistData)
                            putString("timeframe", timeframe)
                            putInt("rsi_period", rsiPeriod)
                            apply()
                        }
                        
                        // Отправляем broadcast для обновления виджета
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
        
        // Обработка Intent при запуске (если приложение открывается из виджета)
        // Виджет теперь обновляется в фоне, но если пользователь кликнет на элемент виджета,
        // приложение откроется с выбранным символом
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        
        // Обработка клика по виджету - открываем приложение с выбранным символом
        val symbol = intent.getStringExtra("symbol")
        if (symbol != null) {
            Log.d(TAG, "Opening app with symbol: $symbol")
            // Flutter обработает это через initialSymbol в HomeScreen
        }
    }
}
