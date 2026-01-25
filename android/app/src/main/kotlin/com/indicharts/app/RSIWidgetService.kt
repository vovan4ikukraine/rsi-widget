package com.indicharts.app

import android.content.Intent
import android.widget.RemoteViews
import android.widget.RemoteViewsService
import android.util.Log
import android.content.Context
import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject
import android.graphics.Color
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.DashPathEffect

/**
 * RemoteViewsService for displaying list items in widget
 */
class RSIWidgetService : RemoteViewsService() {
    
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory {
        return RSIWidgetViewsFactory(this.applicationContext)
    }
}

class RSIWidgetViewsFactory(private val context: Context) : RemoteViewsService.RemoteViewsFactory {
    
    private val items = mutableListOf<WidgetItem>()
    private val TAG = "RSIWidgetViewsFactory"
    
    /**
     * Helper data class for indicator range and levels
     */
    private data class IndicatorRange(val minValue: Float, val maxValue: Float, val upperLevel: Float, val lowerLevel: Float)
    
    data class WidgetItem(
        val symbol: String,
        val rsi: Double, // Keep for backward compatibility
        val indicatorValue: Double, // New field for generic indicator value
        val indicator: String, // Indicator type: "rsi", "stoch", etc.
        val price: Double,
        val rsiValues: List<Double> // Keep for backward compatibility
    )
    
    override fun onCreate() {
        Log.d(TAG, "Factory created")
    }
    
    override fun onDataSetChanged() {
        Log.d(TAG, "onDataSetChanged called - reloading widget data")
        items.clear()
        
        try {
            val prefs = context.getSharedPreferences("rsi_widget_data", Context.MODE_PRIVATE)
            val watchlistJson = prefs.getString("watchlist_data", "[]") ?: "[]"
            
            Log.d(TAG, "Loading widget data from SharedPreferences, JSON length: ${watchlistJson.length}")
            
            if (watchlistJson.isEmpty() || watchlistJson == "[]") {
                Log.w(TAG, "Widget data is empty")
                return
            }
            
            val watchlistArray = JSONArray(watchlistJson)
            Log.d(TAG, "Parsed JSON array with ${watchlistArray.length()} items")
            
            // Read indicator from JSON items (as in cf7559e)
            // The JSON contains the correct indicator type for each item
            // Fallback to SharedPreferences if not found in JSON
            
            for (i in 0 until watchlistArray.length()) {
                try {
                    val item = watchlistArray.getJSONObject(i)
                    val symbol = item.getString("symbol")
                    val indicatorValue = item.optDouble("indicatorValue", item.optDouble("rsi", 0.0))
                    val rsi = item.optDouble("rsi", indicatorValue) // Keep for backward compatibility
                    // Get indicator from JSON item (as in cf7559e), fallback to prefs
                    val indicator = item.optString("indicator", null)?.lowercase() 
                        ?: try {
                            val prefsForIndicator = context.getSharedPreferences("rsi_widget_data", Context.MODE_PRIVATE)
                            prefsForIndicator.getString("widget_indicator", "rsi")?.lowercase() ?: "rsi"
                        } catch (e: Exception) {
                            "rsi"
                        }
                    val price = item.optDouble("price", 0.0)
                    // Parse indicator values array for chart (can be rsiValues or indicatorValues)
                    val indicatorValuesArray = item.optJSONArray("indicatorValues") ?: item.optJSONArray("rsiValues")
                    val rsiValues = mutableListOf<Double>()
                    if (indicatorValuesArray != null) {
                        for (j in 0 until indicatorValuesArray.length()) {
                            rsiValues.add(indicatorValuesArray.getDouble(j))
                        }
                    }
                    
                    items.add(WidgetItem(symbol, rsi, indicatorValue, indicator, price, rsiValues))
                    Log.d(TAG, "Loaded item: $symbol, Indicator: $indicator, Value: $indicatorValue, Price: $price, Chart values: ${rsiValues.size}")
                } catch (e: Exception) {
                    Log.e(TAG, "Error parsing item $i: ${e.message}", e)
                }
            }
            
            // ALWAYS sort items by indicator value (critical for correct display)
            // For RSI and STOCH: ascending (low to high) - smallest values first
            // For WPR: descending (high to low) - since values are negative, -20 > -80, so higher (less negative) first
            if (items.isNotEmpty()) {
                // Determine sort direction based on indicator type
                // Get indicator from first item, or try to get from prefs as fallback (as in cf7559e)
                val indicator = items.firstOrNull()?.indicator?.lowercase() 
                    ?: try {
                        val prefsForIndicator = context.getSharedPreferences("rsi_widget_data", Context.MODE_PRIVATE)
                        prefsForIndicator.getString("widget_indicator", "rsi")?.lowercase() ?: "rsi"
                    } catch (e: Exception) {
                        "rsi"
                    }
                
                val shouldSortDescending = indicator == "wpr" || indicator == "williams"
                
                // Sort items
                items.sortWith { a, b ->
                    val valueA = a.indicatorValue
                    val valueB = b.indicatorValue
                    if (shouldSortDescending) {
                        valueB.compareTo(valueA) // Descending for WPR: -20 before -80
                    } else {
                        valueA.compareTo(valueB) // Ascending for RSI/STOCH: 20 before 80
                    }
                }
                Log.d(TAG, "SORTED ${items.size} items: ${if (shouldSortDescending) "DESCENDING" else "ASCENDING"} for indicator '$indicator'")
                if (items.size > 0) {
                    Log.d(TAG, "First item: ${items.first().symbol}=${items.first().indicatorValue}, Last item: ${items.last().symbol}=${items.last().indicatorValue}")
                }
            } else {
                Log.w(TAG, "No items to sort")
            }
            
            Log.d(TAG, "Successfully loaded ${items.size} items")
        } catch (e: Exception) {
            Log.e(TAG, "Error loading widget data: ${e.message}", e)
            e.printStackTrace()
        }
    }
    
    override fun onDestroy() {
        items.clear()
    }
    
    override fun getCount(): Int = items.size
    
    override fun getViewAt(position: Int): RemoteViews {
        val item = items[position]
        val views = RemoteViews(context.packageName, R.layout.widget_item)
        
        // Set data
        views.setTextViewText(R.id.widget_symbol, item.symbol)
        views.setTextViewText(R.id.widget_rsi, String.format("%.2f", item.indicatorValue))
        views.setTextViewText(R.id.widget_price, String.format("%.2f", item.price))
        
        // Set indicator text color depending on value and indicator type
        val indicatorTextColor = when (item.indicator.lowercase()) {
            "stoch" -> when {
                item.indicatorValue < 20 -> Color.parseColor("#66BB6A") // Green for oversold
                item.indicatorValue > 80 -> Color.parseColor("#EF5350") // Red for overbought
                else -> Color.parseColor("#42A5F5") // Blue for normal state
            }
            "wpr", "williams" -> when {
                item.indicatorValue < -80 -> Color.parseColor("#66BB6A") // Green for oversold (WPR < -80)
                item.indicatorValue > -20 -> Color.parseColor("#EF5350") // Red for overbought (WPR > -20)
                else -> Color.parseColor("#42A5F5") // Blue for normal state
            }
            else -> when { // Default to RSI levels
                item.indicatorValue < 30 -> Color.parseColor("#66BB6A") // Green for oversold
                item.indicatorValue > 70 -> Color.parseColor("#EF5350") // Red for overbought
                else -> Color.parseColor("#42A5F5") // Blue for normal state
            }
        }
        views.setTextColor(R.id.widget_rsi, indicatorTextColor)
        
        // Create indicator chart as Bitmap (increase size for better visibility)
        if (item.rsiValues.isNotEmpty()) {
            Log.d(TAG, "Creating chart for ${item.symbol} at position $position: ${item.rsiValues.size} values, current ${item.indicator.uppercase()}: ${item.indicatorValue}")
            Log.d(TAG, "Chart values range: min=${item.rsiValues.minOrNull()}, max=${item.rsiValues.maxOrNull()}")
            val chartBitmap = createChartBitmap(item.rsiValues, item.indicatorValue, item.indicator, 600, 80)
            views.setImageViewBitmap(R.id.widget_chart, chartBitmap)
            Log.d(TAG, "Chart bitmap created and set for ${item.symbol}")
        } else {
            Log.w(TAG, "No RSI values for ${item.symbol}, skipping chart")
            // Create empty bitmap with semi-transparent background
            val emptyBitmap = Bitmap.createBitmap(600, 80, Bitmap.Config.ARGB_8888)
            emptyBitmap.eraseColor(Color.parseColor("#E01E1E1E"))
            views.setImageViewBitmap(R.id.widget_chart, emptyBitmap)
        }
        
        // Intent for opening app on click
        val fillInIntent = Intent().apply {
            putExtra("symbol", item.symbol)
        }
        views.setOnClickFillInIntent(R.id.widget_item_root, fillInIntent)
        
        return views
    }
    
    private fun createChartBitmap(rsiValues: List<Double>, currentValue: Double, indicator: String, width: Int, height: Int): Bitmap {
        // Increase resolution for better clarity (2x for Retina)
        val scale = 2f
        val scaledWidth = (width * scale).toInt()
        val scaledHeight = (height * scale).toInt()
        
        val bitmap = Bitmap.createBitmap(scaledWidth, scaledHeight, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        
        // Semi-transparent dark background for modern look
        canvas.drawColor(Color.parseColor("#E01E1E1E"))
        
        if (rsiValues.isEmpty()) {
            // Scale back for display
            return Bitmap.createScaledBitmap(bitmap, width, height, true)
        }
        
        // Determine scale and levels based on indicator type
        val rangeData = when (indicator.lowercase()) {
            "wpr", "williams" -> {
                // WPR range: -100 to 0
                IndicatorRange(-100f, 0f, -20f, -80f)
            }
            "stoch" -> {
                // Stochastic range: 0 to 100
                IndicatorRange(0f, 100f, 80f, 20f)
            }
            else -> {
                // RSI range: 0 to 100 (default)
                IndicatorRange(0f, 100f, 70f, 30f)
            }
        }
        val minValue = rangeData.minValue
        val maxValue = rangeData.maxValue
        val upperLevel = rangeData.upperLevel
        val lowerLevel = rangeData.lowerLevel
        
        val padding = 8f * scale
        val chartWidth = scaledWidth - padding * 2
        val chartHeight = scaledHeight - padding * 2
        val valueRange = maxValue - minValue
        
        // Draw zones based on indicator type
        // Overbought zone - dark red with transparency
        val overboughtPaint = Paint().apply {
            color = Color.parseColor("#33F44336") // Red with transparency
            style = Paint.Style.FILL
        }
        // Calculate Y position for upper level based on indicator range
        val normalizedUpperLevel = ((upperLevel - minValue) / valueRange).toFloat()
        val yUpper = padding + (1f - normalizedUpperLevel) * chartHeight
        canvas.drawRect(padding, padding, scaledWidth - padding, yUpper, overboughtPaint)
        
        // Oversold zone - dark green with transparency
        val oversoldPaint = Paint().apply {
            color = Color.parseColor("#334CAF50") // Green with transparency
            style = Paint.Style.FILL
        }
        // Calculate Y position for lower level based on indicator range
        val normalizedLowerLevel = ((lowerLevel - minValue) / valueRange).toFloat()
        val yLower = padding + (1f - normalizedLowerLevel) * chartHeight
        canvas.drawRect(padding, yLower, scaledWidth - padding, scaledHeight - padding, oversoldPaint)
        
        // Draw level lines (thin, more visible)
        val levelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.parseColor("#66FFFFFF") // White with transparency for dark theme
            strokeWidth = 1f * scale
            style = Paint.Style.STROKE
        }
        
        // Upper level line (overbought)
        canvas.drawLine(padding, yUpper, scaledWidth - padding, yUpper, levelPaint)
        
        // Lower level line (oversold)
        canvas.drawLine(padding, yLower, scaledWidth - padding, yLower, levelPaint)
        
        // Middle line (neutral zone) - 50 for RSI/STOCH, -50 for WPR
        val midValue = when (indicator.lowercase()) {
            "wpr", "williams" -> -50f
            else -> 50f
        }
        val normalizedMidValue = ((midValue - minValue) / valueRange).toFloat()
        val yMid = padding + (1f - normalizedMidValue) * chartHeight
        val midLinePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.parseColor("#44FFFFFF")
            strokeWidth = 0.5f * scale
            style = Paint.Style.STROKE
            pathEffect = DashPathEffect(floatArrayOf(4f * scale, 4f * scale), 0f)
        }
        canvas.drawLine(padding, yMid, scaledWidth - padding, yMid, midLinePaint)
        
        // Draw chart (thin, clear line, color depends on current indicator value)
        val lineColor = when (indicator.lowercase()) {
            "stoch" -> when {
                currentValue < 20 -> Color.parseColor("#66BB6A") // Light green - oversold
                currentValue > 80 -> Color.parseColor("#EF5350") // Light red - overbought
                else -> Color.parseColor("#42A5F5") // Light blue - normal
            }
            "wpr", "williams" -> when {
                currentValue < -80 -> Color.parseColor("#66BB6A") // Light green - oversold (WPR < -80)
                currentValue > -20 -> Color.parseColor("#EF5350") // Light red - overbought (WPR > -20)
                else -> Color.parseColor("#42A5F5") // Light blue - normal
            }
            else -> when { // Default to RSI levels
                currentValue < 30 -> Color.parseColor("#66BB6A") // Light green - oversold
                currentValue > 70 -> Color.parseColor("#EF5350") // Light red - overbought
                else -> Color.parseColor("#42A5F5") // Light blue - normal
            }
        }
        
        val linePaint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG).apply {
            color = lineColor
            style = Paint.Style.STROKE
            strokeWidth = 2f * scale // Thin line (equivalent to 1px at scale)
            strokeCap = Paint.Cap.ROUND
            strokeJoin = Paint.Join.ROUND
            isAntiAlias = true
        }
        
        val path = Path()
        val stepX = if (rsiValues.size > 1) chartWidth / (rsiValues.size - 1) else 0f
        
        rsiValues.forEachIndexed { index, value ->
            val x = padding + index * stepX
            // Clamp value to indicator's range
            val clampedValue = value.coerceIn(minValue.toDouble(), maxValue.toDouble())
            // Convert value to Y coordinate (0 at top, height at bottom)
            // For WPR: -100 at top (y=padding), 0 at bottom (y=padding+chartHeight)
            // For RSI/STOCH: 0 at bottom (y=padding+chartHeight), 100 at top (y=padding)
            val normalizedValue = ((clampedValue - minValue) / valueRange).toFloat()
            val y = padding + (1f - normalizedValue) * chartHeight
            
            if (index == 0) {
                path.moveTo(x, y)
            } else {
                path.lineTo(x, y)
            }
        }
        
        canvas.drawPath(path, linePaint)
        
        // Draw points on extrema (maxima and minima) - thinner
        val pointPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.FILL
        }
        
        if (rsiValues.isNotEmpty()) {
            val dataMaxValue = rsiValues.maxOrNull() ?: 0.0
            val dataMinValue = rsiValues.minOrNull() ?: 0.0
            val maxIndex = rsiValues.indexOf(dataMaxValue)
            val minIndex = rsiValues.indexOf(dataMinValue)
            
            // Maximum point (if above upper level for RSI/STOCH, or above upper level for WPR)
            val shouldShowMax = when (indicator.lowercase()) {
                "wpr", "williams" -> dataMaxValue > upperLevel // For WPR, upperLevel is -20
                else -> dataMaxValue > upperLevel
            }
            if (shouldShowMax) {
                val maxX = padding + maxIndex * stepX
                val normalizedMaxValue = ((dataMaxValue.coerceIn(minValue.toDouble(), maxValue.toDouble()) - minValue) / valueRange).toFloat()
                val maxY = padding + (1f - normalizedMaxValue) * chartHeight
                pointPaint.color = Color.parseColor("#EF5350")
                canvas.drawCircle(maxX, maxY, 3f * scale, pointPaint)
            }
            
            // Minimum point (if below lower level)
            val shouldShowMin = when (indicator.lowercase()) {
                "wpr", "williams" -> dataMinValue < lowerLevel // For WPR, lowerLevel is -80
                else -> dataMinValue < lowerLevel
            }
            if (shouldShowMin) {
                val minX = padding + minIndex * stepX
                val normalizedMinValue = ((dataMinValue.coerceIn(minValue.toDouble(), maxValue.toDouble()) - minValue) / valueRange).toFloat()
                val minY = padding + (1f - normalizedMinValue) * chartHeight
                pointPaint.color = Color.parseColor("#66BB6A")
                canvas.drawCircle(minX, minY, 3f * scale, pointPaint)
            }
            
            // Current point (last point) - slightly larger
            val lastIndex = rsiValues.size - 1
            val lastX = padding + lastIndex * stepX
            val clampedCurrentValue = currentValue.coerceIn(minValue.toDouble(), maxValue.toDouble())
            val normalizedCurrentValue = ((clampedCurrentValue - minValue) / valueRange).toFloat()
            val lastY = padding + (1f - normalizedCurrentValue) * chartHeight
            pointPaint.color = lineColor
            // Draw outline for better visibility
            pointPaint.style = Paint.Style.FILL
            canvas.drawCircle(lastX, lastY, 3.5f * scale, pointPaint)
            pointPaint.color = Color.parseColor("#E01E1E1E")
            canvas.drawCircle(lastX, lastY, 2f * scale, pointPaint)
        }
        
        // Scale back for display (with filtering for clarity)
        return Bitmap.createScaledBitmap(bitmap, width, height, true)
    }
    
    override fun getLoadingView(): RemoteViews? = null
    
    override fun getViewTypeCount(): Int = 1
    
    override fun getItemId(position: Int): Long = position.toLong()
    
    override fun hasStableIds(): Boolean = true
}


