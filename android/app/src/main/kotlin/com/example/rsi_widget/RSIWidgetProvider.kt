package com.example.rsi_widget

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import android.util.Log
import org.json.JSONArray
import android.graphics.Color
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay

/**
 * App Widget Provider для отображения Watchlist с графиками RSI
 */
class RSIWidgetProvider : AppWidgetProvider() {
    
    companion object {
        private const val TAG = "RSIWidgetProvider"
        const val ACTION_UPDATE_WIDGET = "com.example.rsi_widget.UPDATE_WIDGET"
        const val ACTION_REFRESH_WIDGET = "com.example.rsi_widget.REFRESH_WIDGET"
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        Log.d(TAG, "onUpdate called for ${appWidgetIds.size} widgets")
        
        // Обновляем все виджеты
        for (appWidgetId in appWidgetIds) {
            updateAppWidget(context, appWidgetManager, appWidgetId)
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        
        when (intent.action) {
            ACTION_UPDATE_WIDGET -> {
                val appWidgetManager = AppWidgetManager.getInstance(context)
                val appWidgetIds = appWidgetManager.getAppWidgetIds(
                    android.content.ComponentName(context, RSIWidgetProvider::class.java)
                )
                
                Log.d(TAG, "Received update action for ${appWidgetIds.size} widgets")
                
                // Обновляем все виджеты
                for (appWidgetId in appWidgetIds) {
                    updateAppWidget(context, appWidgetManager, appWidgetId)
                }
            }
            "com.example.rsi_widget.CHANGE_TIMEFRAME" -> {
                val newTimeframe = intent.getStringExtra("timeframe") ?: "15m"
                val appWidgetId = intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
                
                Log.d(TAG, "Changing timeframe to $newTimeframe for widget $appWidgetId")
                
                // Сохраняем новый таймфрейм в SharedPreferences
                val prefs = context.getSharedPreferences("rsi_widget_data", Context.MODE_PRIVATE)
                // Используем период из виджета, если установлен, иначе из общих настроек
                val rsiPeriod = prefs.getInt("rsi_widget_period", 
                    prefs.getInt("rsi_period", 14))
                prefs.edit().apply {
                    putString("timeframe", newTimeframe)
                    putString("rsi_widget_timeframe", newTimeframe)
                    putInt("rsi_widget_period", rsiPeriod)
                    commit() // Используем commit для синхронного сохранения
                }
                
                Log.d(TAG, "Saved timeframe: $newTimeframe, period: $rsiPeriod")
                
                // Сразу обновляем UI виджета с новым таймфреймом
                val appWidgetManager = AppWidgetManager.getInstance(context)
                if (appWidgetId != AppWidgetManager.INVALID_APPWIDGET_ID) {
                    updateAppWidget(context, appWidgetManager, appWidgetId)
                } else {
                    val appWidgetIds = appWidgetManager.getAppWidgetIds(
                        android.content.ComponentName(context, RSIWidgetProvider::class.java)
                    )
                    for (id in appWidgetIds) {
                        updateAppWidget(context, appWidgetManager, id)
                    }
                }
                
                // Загружаем данные в фоне БЕЗ запуска Activity
                CoroutineScope(Dispatchers.IO).launch {
                    Log.d(TAG, "Starting background data refresh for timeframe: $newTimeframe")
                    val success = WidgetDataService.refreshWidgetData(context)
                    Log.d(TAG, "Background data refresh completed: success=$success")
                    
                    if (success) {
                        // Небольшая задержка, чтобы данные точно сохранились
                        kotlinx.coroutines.delay(100)
                        
                        // Обновляем виджет после загрузки данных на главном потоке
                        android.os.Handler(android.os.Looper.getMainLooper()).post {
                            try {
                                val manager = AppWidgetManager.getInstance(context)
                                val ids = manager.getAppWidgetIds(
                                    android.content.ComponentName(context, RSIWidgetProvider::class.java)
                                )
                                Log.d(TAG, "Updating ${ids.size} widget(s) after data refresh")
                                
                                // Проверяем, что данные действительно сохранены
                                val prefs = context.getSharedPreferences("rsi_widget_data", Context.MODE_PRIVATE)
                                val savedData = prefs.getString("watchlist_data", "[]")
                                Log.d(TAG, "Verifying saved data: length=${savedData?.length ?: 0}")
                                
                                for (id in ids) {
                                    // Сначала обновляем UI виджета (заголовок, кнопки)
                                    updateAppWidget(context, manager, id)
                                    
                                    // Затем принудительно обновляем данные в списке
                                    // Это вызовет onDataSetChanged() в RSIWidgetService
                                    manager.notifyAppWidgetViewDataChanged(id, R.id.widget_list)
                                    
                                    // Обновляем виджет еще раз, чтобы применить изменения
                                    updateAppWidget(context, manager, id)
                                }
                                Log.d(TAG, "Widget(s) updated successfully after data refresh")
                            } catch (e: Exception) {
                                Log.e(TAG, "Error updating widget after refresh: ${e.message}", e)
                                e.printStackTrace()
                            }
                        }
                    } else {
                        Log.w(TAG, "Background data refresh failed, widget not updated")
                    }
                }
            }
            ACTION_REFRESH_WIDGET -> {
                val appWidgetId = intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
                
                Log.d(TAG, "Refresh widget requested for widget $appWidgetId")
                
                // Получаем текущий таймфрейм из настроек
                val prefs = context.getSharedPreferences("rsi_widget_data", Context.MODE_PRIVATE)
                val currentTimeframe = prefs.getString("timeframe", "15m") ?: "15m"
                
                // Сразу обновляем виджет с существующими данными
                val appWidgetManager = AppWidgetManager.getInstance(context)
                if (appWidgetId != AppWidgetManager.INVALID_APPWIDGET_ID) {
                    updateAppWidget(context, appWidgetManager, appWidgetId)
                    appWidgetManager.notifyAppWidgetViewDataChanged(appWidgetId, R.id.widget_list)
                } else {
                    val appWidgetIds = appWidgetManager.getAppWidgetIds(
                        android.content.ComponentName(context, RSIWidgetProvider::class.java)
                    )
                    for (id in appWidgetIds) {
                        updateAppWidget(context, appWidgetManager, id)
                        appWidgetManager.notifyAppWidgetViewDataChanged(id, R.id.widget_list)
                    }
                }
                
                // Загружаем данные в фоне БЕЗ запуска Activity
                CoroutineScope(Dispatchers.IO).launch {
                    Log.d(TAG, "Starting background data refresh for timeframe: $currentTimeframe")
                    val success = WidgetDataService.refreshWidgetData(context)
                    Log.d(TAG, "Background data refresh completed: success=$success")
                    
                    if (success) {
                        // Небольшая задержка, чтобы данные точно сохранились
                        kotlinx.coroutines.delay(100)
                        
                        // Обновляем виджет после загрузки данных на главном потоке
                        android.os.Handler(android.os.Looper.getMainLooper()).post {
                            try {
                                val manager = AppWidgetManager.getInstance(context)
                                val ids = manager.getAppWidgetIds(
                                    android.content.ComponentName(context, RSIWidgetProvider::class.java)
                                )
                                Log.d(TAG, "Updating ${ids.size} widget(s) after data refresh")
                                
                                // Проверяем, что данные действительно сохранены
                                val prefs = context.getSharedPreferences("rsi_widget_data", Context.MODE_PRIVATE)
                                val savedData = prefs.getString("watchlist_data", "[]")
                                Log.d(TAG, "Verifying saved data: length=${savedData?.length ?: 0}")
                                
                                for (id in ids) {
                                    // Сначала обновляем UI виджета (заголовок, кнопки)
                                    updateAppWidget(context, manager, id)
                                    
                                    // Затем принудительно обновляем данные в списке
                                    // Это вызовет onDataSetChanged() в RSIWidgetService
                                    manager.notifyAppWidgetViewDataChanged(id, R.id.widget_list)
                                    
                                    // Обновляем виджет еще раз, чтобы применить изменения
                                    updateAppWidget(context, manager, id)
                                }
                                Log.d(TAG, "Widget(s) updated successfully after data refresh")
                            } catch (e: Exception) {
                                Log.e(TAG, "Error updating widget after refresh: ${e.message}", e)
                                e.printStackTrace()
                            }
                        }
                    } else {
                        Log.w(TAG, "Background data refresh failed, widget not updated")
                    }
                }
            }
        }
    }

    override fun onEnabled(context: Context) {
        Log.d(TAG, "Widget enabled")
    }

    override fun onDisabled(context: Context) {
        Log.d(TAG, "Widget disabled")
    }

    private fun updateAppWidget(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int
    ) {
        try {
            // Загружаем данные из SharedPreferences (переданные из Flutter)
            val prefs = context.getSharedPreferences("rsi_widget_data", Context.MODE_PRIVATE)
            val watchlistJson = prefs.getString("watchlist_data", "[]")
            val timeframe = prefs.getString("timeframe", "15m") ?: "15m"
            val rsiPeriod = prefs.getInt("rsi_period", 14)
            
            Log.d(TAG, "Updating widget $appWidgetId")
            Log.d(TAG, "Data JSON length: ${watchlistJson?.length ?: 0}, timeframe: $timeframe, period: $rsiPeriod")
            
            val views = RemoteViews(context.packageName, R.layout.widget_layout)
            
            // Парсим JSON данные
            val watchlistArray = if (watchlistJson.isNullOrEmpty() || watchlistJson == "[]") {
                JSONArray()
            } else {
                try {
                    JSONArray(watchlistJson)
                } catch (e: Exception) {
                    Log.e(TAG, "Error parsing watchlist JSON: ${e.message}", e)
                    JSONArray()
                }
            }
            
            Log.d(TAG, "Parsed ${watchlistArray.length()} items from JSON")
            
            if (watchlistArray.length() == 0) {
                // Нет данных - показываем пустое состояние
                views.setTextViewText(R.id.widget_title, "RSI Watchlist")
                views.setTextViewText(R.id.widget_empty_text, "Добавьте инструменты в Watchlist")
                views.setViewVisibility(R.id.widget_empty_text, android.view.View.VISIBLE)
                views.setViewVisibility(R.id.widget_list, android.view.View.GONE)
                views.setViewVisibility(R.id.widget_timeframe_selector, android.view.View.GONE)
            } else {
                // Есть данные - показываем список
                views.setTextViewText(R.id.widget_title, "RSI Watchlist ($timeframe, RSI($rsiPeriod))")
                views.setViewVisibility(R.id.widget_empty_text, android.view.View.GONE)
                views.setViewVisibility(R.id.widget_list, android.view.View.VISIBLE)
                views.setViewVisibility(R.id.widget_timeframe_selector, android.view.View.VISIBLE)
                
                // Устанавливаем адаптер для списка
                val intent = Intent(context, RSIWidgetService::class.java).apply {
                    putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId)
                }
                views.setRemoteAdapter(R.id.widget_list, intent)
                
                // Устанавливаем обработчик кликов
                val pendingIntent = android.app.PendingIntent.getActivity(
                    context,
                    0,
                    context.packageManager.getLaunchIntentForPackage(context.packageName),
                    android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE
                )
                views.setPendingIntentTemplate(R.id.widget_list, pendingIntent)
                
                // Устанавливаем обработчики для кнопок выбора таймфрейма
                val timeframeButtons = mapOf(
                    R.id.widget_tf_1m to "1m",
                    R.id.widget_tf_5m to "5m",
                    R.id.widget_tf_15m to "15m",
                    R.id.widget_tf_1h to "1h",
                    R.id.widget_tf_4h to "4h",
                    R.id.widget_tf_1d to "1d"
                )
                
                timeframeButtons.forEach { (buttonId, tf) ->
                    val tfIntent = Intent(context, RSIWidgetProvider::class.java).apply {
                        action = "com.example.rsi_widget.CHANGE_TIMEFRAME"
                        putExtra("timeframe", tf)
                        putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId)
                    }
                    val tfPendingIntent = android.app.PendingIntent.getBroadcast(
                        context,
                        buttonId,
                        tfIntent,
                        android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE
                    )
                    views.setOnClickPendingIntent(buttonId, tfPendingIntent)
                    
                    // Подсвечиваем текущий таймфрейм (современный дизайн для темной темы)
                    if (tf == timeframe) {
                        views.setInt(buttonId, "setBackgroundResource", R.drawable.widget_button_active_background)
                        views.setTextColor(buttonId, Color.parseColor("#FFFFFF"))
                    } else {
                        views.setInt(buttonId, "setBackgroundResource", R.drawable.widget_button_background)
                        views.setTextColor(buttonId, Color.parseColor("#E0E0E0"))
                    }
                }
                
                // Устанавливаем обработчик для кнопки обновления
                val refreshIntent = Intent(context, RSIWidgetProvider::class.java).apply {
                    action = ACTION_REFRESH_WIDGET
                    putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId)
                }
                val refreshPendingIntent = android.app.PendingIntent.getBroadcast(
                    context,
                    0,
                    refreshIntent,
                    android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE
                )
                views.setOnClickPendingIntent(R.id.widget_refresh_button, refreshPendingIntent)
            }
            
            // Обновляем виджет
            appWidgetManager.updateAppWidget(appWidgetId, views)
            appWidgetManager.notifyAppWidgetViewDataChanged(appWidgetId, R.id.widget_list)
            
            Log.d(TAG, "Widget $appWidgetId updated successfully")
        } catch (e: Exception) {
            Log.e(TAG, "Error updating widget $appWidgetId", e)
        }
    }
}

