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
 * App Widget Provider for displaying Watchlist with RSI charts
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
        
        // Update all widgets
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
                
                // Update all widgets
                for (appWidgetId in appWidgetIds) {
                    updateAppWidget(context, appWidgetManager, appWidgetId)
                }
            }
            "com.example.rsi_widget.CHANGE_TIMEFRAME" -> {
                val newTimeframe = intent.getStringExtra("timeframe") ?: "15m"
                val appWidgetId = intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
                
                Log.d(TAG, "Changing timeframe to $newTimeframe for widget $appWidgetId")
                
                // Save new timeframe to SharedPreferences
                val prefs = context.getSharedPreferences("rsi_widget_data", Context.MODE_PRIVATE)
                // Use period from widget if set, otherwise from general settings
                val rsiPeriod = prefs.getInt("rsi_widget_period", 
                    prefs.getInt("rsi_period", 14))
                prefs.edit().apply {
                    putString("timeframe", newTimeframe)
                    putString("rsi_widget_timeframe", newTimeframe)
                    putInt("rsi_widget_period", rsiPeriod)
                    commit() // Use commit for synchronous save
                }
                
                Log.d(TAG, "Saved timeframe: $newTimeframe, period: $rsiPeriod")
                
                // Immediately update widget UI with new timeframe
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
                
                // Load data in background WITHOUT launching Activity
                CoroutineScope(Dispatchers.IO).launch {
                    Log.d(TAG, "Starting background data refresh for timeframe: $newTimeframe")
                    val success = WidgetDataService.refreshWidgetData(context)
                    Log.d(TAG, "Background data refresh completed: success=$success")
                    
                    if (success) {
                        // Small delay to ensure data is saved
                        kotlinx.coroutines.delay(100)
                        
                        // Update widget after loading data on main thread
                        android.os.Handler(android.os.Looper.getMainLooper()).post {
                            try {
                                val manager = AppWidgetManager.getInstance(context)
                                val ids = manager.getAppWidgetIds(
                                    android.content.ComponentName(context, RSIWidgetProvider::class.java)
                                )
                                Log.d(TAG, "Updating ${ids.size} widget(s) after data refresh")
                                
                                // Verify that data was actually saved
                                val prefs = context.getSharedPreferences("rsi_widget_data", Context.MODE_PRIVATE)
                                val savedData = prefs.getString("watchlist_data", "[]")
                                Log.d(TAG, "Verifying saved data: length=${savedData?.length ?: 0}")
                                
                                for (id in ids) {
                                    // First update widget UI (title, buttons)
                                    updateAppWidget(context, manager, id)
                                    
                                    // Then forcefully update data in list
                                    // This will call onDataSetChanged() in RSIWidgetService
                                    manager.notifyAppWidgetViewDataChanged(id, R.id.widget_list)
                                    
                                    // Update widget once more to apply changes
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
                
                // Get current timeframe from settings
                val prefs = context.getSharedPreferences("rsi_widget_data", Context.MODE_PRIVATE)
                val currentTimeframe = prefs.getString("timeframe", "15m") ?: "15m"
                
                // Immediately update widget with existing data
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
                
                // Load data in background WITHOUT launching Activity
                CoroutineScope(Dispatchers.IO).launch {
                    Log.d(TAG, "Starting background data refresh for timeframe: $currentTimeframe")
                    val success = WidgetDataService.refreshWidgetData(context)
                    Log.d(TAG, "Background data refresh completed: success=$success")
                    
                    if (success) {
                        // Small delay to ensure data is saved
                        kotlinx.coroutines.delay(100)
                        
                        // Update widget after loading data on main thread
                        android.os.Handler(android.os.Looper.getMainLooper()).post {
                            try {
                                val manager = AppWidgetManager.getInstance(context)
                                val ids = manager.getAppWidgetIds(
                                    android.content.ComponentName(context, RSIWidgetProvider::class.java)
                                )
                                Log.d(TAG, "Updating ${ids.size} widget(s) after data refresh")
                                
                                // Verify that data was actually saved
                                val prefs = context.getSharedPreferences("rsi_widget_data", Context.MODE_PRIVATE)
                                val savedData = prefs.getString("watchlist_data", "[]")
                                Log.d(TAG, "Verifying saved data: length=${savedData?.length ?: 0}")
                                
                                for (id in ids) {
                                    // First update widget UI (title, buttons)
                                    updateAppWidget(context, manager, id)
                                    
                                    // Then forcefully update data in list
                                    // This will call onDataSetChanged() in RSIWidgetService
                                    manager.notifyAppWidgetViewDataChanged(id, R.id.widget_list)
                                    
                                    // Update widget once more to apply changes
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
            // Load data from SharedPreferences (passed from Flutter)
            val prefs = context.getSharedPreferences("rsi_widget_data", Context.MODE_PRIVATE)
            val watchlistJson = prefs.getString("watchlist_data", "[]")
            val timeframe = prefs.getString("timeframe", "15m") ?: "15m"
            val rsiPeriod = prefs.getInt("rsi_period", 14)
            
            Log.d(TAG, "Updating widget $appWidgetId")
            Log.d(TAG, "Data JSON length: ${watchlistJson?.length ?: 0}, timeframe: $timeframe, period: $rsiPeriod")
            
            val views = RemoteViews(context.packageName, R.layout.widget_layout)
            
            // Parse JSON data
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
                // No data - show empty state
                views.setTextViewText(R.id.widget_title, "RSI Watchlist")
                views.setTextViewText(R.id.widget_empty_text, "Add instruments to Watchlist")
                views.setViewVisibility(R.id.widget_empty_text, android.view.View.VISIBLE)
                views.setViewVisibility(R.id.widget_list, android.view.View.GONE)
                views.setViewVisibility(R.id.widget_timeframe_selector, android.view.View.GONE)
            } else {
                // Has data - show list
                views.setTextViewText(R.id.widget_title, "RSI Watchlist ($timeframe, RSI($rsiPeriod))")
                views.setViewVisibility(R.id.widget_empty_text, android.view.View.GONE)
                views.setViewVisibility(R.id.widget_list, android.view.View.VISIBLE)
                views.setViewVisibility(R.id.widget_timeframe_selector, android.view.View.VISIBLE)
                
                // Set adapter for list
                val intent = Intent(context, RSIWidgetService::class.java).apply {
                    putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId)
                }
                views.setRemoteAdapter(R.id.widget_list, intent)
                
                // Set click handler
                val pendingIntent = android.app.PendingIntent.getActivity(
                    context,
                    0,
                    context.packageManager.getLaunchIntentForPackage(context.packageName),
                    android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE
                )
                views.setPendingIntentTemplate(R.id.widget_list, pendingIntent)
                
                // Set handlers for timeframe selection buttons
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
                    
                    // Highlight current timeframe (modern design for dark theme)
                    if (tf == timeframe) {
                        views.setInt(buttonId, "setBackgroundResource", R.drawable.widget_button_active_background)
                        views.setTextColor(buttonId, Color.parseColor("#FFFFFF"))
                    } else {
                        views.setInt(buttonId, "setBackgroundResource", R.drawable.widget_button_background)
                        views.setTextColor(buttonId, Color.parseColor("#E0E0E0"))
                    }
                }
                
                // Set handler for refresh button
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
            
            // Update widget
            appWidgetManager.updateAppWidget(appWidgetId, views)
            appWidgetManager.notifyAppWidgetViewDataChanged(appWidgetId, R.id.widget_list)
            
            Log.d(TAG, "Widget $appWidgetId updated successfully")
        } catch (e: Exception) {
            Log.e(TAG, "Error updating widget $appWidgetId", e)
        }
    }
}

