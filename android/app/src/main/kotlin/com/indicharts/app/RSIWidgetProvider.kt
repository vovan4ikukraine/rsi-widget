package com.indicharts.app

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.View
import android.widget.RemoteViews
import org.json.JSONArray
import android.graphics.Color
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * App Widget Provider for displaying Watchlist with RSI charts
 */
class RSIWidgetProvider : AppWidgetProvider() {
    
    companion object {
        private const val TAG = "RSIWidgetProvider"
        const val ACTION_UPDATE_WIDGET = "com.indicharts.app.UPDATE_WIDGET"
        const val ACTION_REFRESH_WIDGET = "com.indicharts.app.REFRESH_WIDGET"
        private val widgetScope = CoroutineScope(Dispatchers.IO)
        @Volatile private var currentRefreshJob: Job? = null
        @Volatile private var currentRequestId: Long = 0
        private const val PREF_PENDING_REQUEST_ID = "pending_request_id"
        private const val PREF_IS_LOADING = "is_loading"
    }

    private fun setLoadingState(context: Context, isLoading: Boolean) {
        val prefs = context.getSharedPreferences("rsi_widget_data", Context.MODE_PRIVATE)
        prefs.edit().putBoolean(PREF_IS_LOADING, isLoading).apply()

        Handler(Looper.getMainLooper()).post {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(
                android.content.ComponentName(context, RSIWidgetProvider::class.java)
            )
            ids.forEach { updateAppWidget(context, manager, it) }
        }
    }

    private fun startRefreshJob(context: Context) {
        val requestId = ++currentRequestId
        val prefs = context.getSharedPreferences("rsi_widget_data", Context.MODE_PRIVATE)
        prefs.edit().putLong(PREF_PENDING_REQUEST_ID, requestId).apply()

        setLoadingState(context, true)

        currentRefreshJob?.cancel()
        currentRefreshJob = widgetScope.launch {
            try {
                val success = WidgetDataService.refreshWidgetData(context, requestId)
                withContext(Dispatchers.Main) {
                    if (currentRequestId == requestId) {
                        setLoadingState(context, false)
                        if (success) {
                            val manager = AppWidgetManager.getInstance(context)
                            val ids = manager.getAppWidgetIds(
                                android.content.ComponentName(context, RSIWidgetProvider::class.java)
                            )
                            ids.forEach { id ->
                                updateAppWidget(context, manager, id)
                                manager.notifyAppWidgetViewDataChanged(id, R.id.widget_list)
                            }
                        }
                    }
                }
            } catch (e: Exception) {
                withContext(Dispatchers.Main) {
                    if (currentRequestId == requestId) {
                        setLoadingState(context, false)
                    }
                }
                Log.e(TAG, "Error refreshing widget data: ${e.message}", e)
            }
        }
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
            "com.indicharts.app.CHANGE_TIMEFRAME" -> {
                val newTimeframe = intent.getStringExtra("timeframe") ?: "15m"
                val appWidgetId = intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
                
                Log.d(TAG, "Changing timeframe to $newTimeframe for widget $appWidgetId")
                
                // Save new timeframe to SharedPreferences
                // CRITICAL: Read period and params for CURRENT indicator, not generic rsi_widget_period
                // This ensures STOCH uses correct %K period and %D period, not WPR/RSI periods
                val prefs = context.getSharedPreferences("rsi_widget_data", Context.MODE_PRIVATE)
                val currentIndicator = prefs.getString("widget_indicator", "rsi") ?: "rsi"
                
                // Get period for current indicator: try watchlist/home settings first, then default
                // DO NOT use rsi_widget_period as fallback as it may contain stale value from previous indicator
                val watchlistPeriodKey = "watchlist_${currentIndicator}_period"
                val homePeriodKey = "home_${currentIndicator}_period"
                val watchlistPeriod = prefs.getInt(watchlistPeriodKey, -1)
                val homePeriod = prefs.getInt(homePeriodKey, -1)
                val rsiPeriod = when {
                    watchlistPeriod != -1 -> watchlistPeriod
                    homePeriod != -1 -> homePeriod
                    else -> when (currentIndicator.lowercase()) {
                        "stoch" -> 6
                        "wpr", "williams" -> 14
                        else -> 14
                    }
                }
                
                // For STOCH, ALWAYS read %D period from watchlist/home settings (even if widget_indicator_params exists)
                // This ensures that changes in watchlist STOCH %D period are reflected in widget
                var indicatorParamsJson = prefs.getString("widget_indicator_params", null)
                if (currentIndicator.lowercase() == "stoch") {
                    // Get %D period for STOCH from watchlist/home settings (priority: watchlist > home > default)
                    val stochDPeriod = prefs.getInt("watchlist_stoch_d_period",
                        prefs.getInt("home_stoch_d_period", 3))
                    indicatorParamsJson = "{\"dPeriod\":$stochDPeriod}"
                }
                
                prefs.edit().apply {
                    putString("timeframe", newTimeframe)
                    putString("rsi_widget_timeframe", newTimeframe)
                    putInt("rsi_widget_period", rsiPeriod) // Save for compatibility
                    if (indicatorParamsJson != null) {
                        putString("widget_indicator_params", indicatorParamsJson)
                    }
                    commit() // Use commit for synchronous save
                }
                
                Log.d(TAG, "Saved timeframe: $newTimeframe, indicator: $currentIndicator, period: $rsiPeriod, params: $indicatorParamsJson")
                
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
                
                startRefreshJob(context)
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
                
                startRefreshJob(context)
            }
        }
    }

    override fun onEnabled(context: Context) {
        Log.d(TAG, "Widget enabled")
        // Kick off initial refresh as soon as widget is added.
        startRefreshJob(context)
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
            val indicator = prefs.getString("widget_indicator", "rsi") ?: "rsi"
            
            // CRITICAL: Read period for CURRENT indicator from watchlist/home settings
            // Priority: watchlist_${indicator}_period > home_${indicator}_period > defaults
            // DO NOT use rsi_widget_period as it may contain stale value from previous indicator
            val watchlistPeriodKey = "watchlist_${indicator}_period"
            val homePeriodKey = "home_${indicator}_period"
            val watchlistPeriod = prefs.getInt(watchlistPeriodKey, -1)
            val homePeriod = prefs.getInt(homePeriodKey, -1)
            val rsiPeriod = when {
                watchlistPeriod != -1 -> watchlistPeriod
                homePeriod != -1 -> homePeriod
                else -> when (indicator.lowercase()) {
                    "stoch" -> 6
                    "wpr", "williams" -> 14
                    else -> 14
                }
            }
            
            // For STOCH, read %D period for display
            var stochDPeriod: Int? = null
            if (indicator.lowercase() == "stoch") {
                stochDPeriod = prefs.getInt("watchlist_stoch_d_period",
                    prefs.getInt("home_stoch_d_period", 3))
            }
            
            val isLoading = prefs.getBoolean(PREF_IS_LOADING, false)
            
            Log.d(TAG, "Updating widget $appWidgetId")
            Log.d(TAG, "Data JSON length: ${watchlistJson?.length ?: 0}, timeframe: $timeframe, period: $rsiPeriod, indicator: $indicator")
            
            val views = RemoteViews(context.packageName, R.layout.widget_layout)
            views.setViewVisibility(
                R.id.widget_loading_text,
                if (isLoading) View.VISIBLE else View.GONE
            )
            
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
                views.setViewVisibility(R.id.widget_empty_text, View.VISIBLE)
                views.setViewVisibility(R.id.widget_list, View.GONE)
                views.setViewVisibility(R.id.widget_timeframe_selector, View.GONE)
                views.setViewVisibility(R.id.widget_loading_text, View.GONE)
            } else {
                // Has data - show list
                val indicatorName = indicator.uppercase()
                // For STOCH, show both kPeriod and dPeriod: STOCH(kPeriod, dPeriod)
                // For other indicators, show single period: RSI(14) or WPR(14)
                val periodText = if (indicator.lowercase() == "stoch" && stochDPeriod != null) {
                    "$rsiPeriod, $stochDPeriod"
                } else {
                    rsiPeriod.toString()
                }
                views.setTextViewText(R.id.widget_title, "Watchlist ($timeframe, $indicatorName($periodText))")
                views.setViewVisibility(R.id.widget_empty_text, View.GONE)
                views.setViewVisibility(R.id.widget_list, View.VISIBLE)
                views.setViewVisibility(R.id.widget_timeframe_selector, View.VISIBLE)
                
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
                        action = "com.indicharts.app.CHANGE_TIMEFRAME"
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

