package com.example.rsi_widget

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
    
    data class WidgetItem(
        val symbol: String,
        val rsi: Double,
        val price: Double,
        val rsiValues: List<Double>
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
            
            for (i in 0 until watchlistArray.length()) {
                try {
                    val item = watchlistArray.getJSONObject(i)
                    val symbol = item.getString("symbol")
                    val rsi = item.optDouble("rsi", 0.0)
                    val price = item.optDouble("price", 0.0)
                    // Parse RSI values array for chart
                    val rsiValuesArray = item.optJSONArray("rsiValues")
                    val rsiValues = mutableListOf<Double>()
                    if (rsiValuesArray != null) {
                        for (j in 0 until rsiValuesArray.length()) {
                            rsiValues.add(rsiValuesArray.getDouble(j))
                        }
                    }
                    
                    items.add(WidgetItem(symbol, rsi, price, rsiValues))
                    Log.d(TAG, "Loaded item: $symbol, RSI: $rsi, Price: $price, RSI values: ${rsiValues.size}")
                } catch (e: Exception) {
                    Log.e(TAG, "Error parsing item $i: ${e.message}", e)
                }
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
        views.setTextViewText(R.id.widget_rsi, String.format("%.2f", item.rsi))
        views.setTextViewText(R.id.widget_price, String.format("%.2f", item.price))
        
        // Set RSI text color depending on value
        val rsiTextColor = when {
            item.rsi < 30 -> Color.parseColor("#66BB6A") // Green for oversold
            item.rsi > 70 -> Color.parseColor("#EF5350") // Red for overbought
            else -> Color.parseColor("#42A5F5") // Blue for normal state
        }
        views.setTextColor(R.id.widget_rsi, rsiTextColor)
        
        // Create RSI chart as Bitmap (increase size for better visibility)
        if (item.rsiValues.isNotEmpty()) {
            Log.d(TAG, "Creating chart for ${item.symbol} at position $position: ${item.rsiValues.size} values, current RSI: ${item.rsi}")
            Log.d(TAG, "Chart values range: min=${item.rsiValues.minOrNull()}, max=${item.rsiValues.maxOrNull()}")
            val chartBitmap = createChartBitmap(item.rsiValues, item.rsi, 600, 80)
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
    
    private fun createChartBitmap(rsiValues: List<Double>, currentRsi: Double, width: Int, height: Int): Bitmap {
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
        
        // Use fixed 0-100 scale for RSI
        val padding = 8f * scale
        val chartWidth = scaledWidth - padding * 2
        val chartHeight = scaledHeight - padding * 2
        
        // Overbought zone (above 70) - dark red with transparency
        val overboughtPaint = Paint().apply {
            color = Color.parseColor("#33F44336") // Red with transparency
            style = Paint.Style.FILL
        }
        val y70 = padding + ((100 - 70) / 100f) * chartHeight
        canvas.drawRect(padding, padding, scaledWidth - padding, y70, overboughtPaint)
        
        // Oversold zone (below 30) - dark green with transparency
        val oversoldPaint = Paint().apply {
            color = Color.parseColor("#334CAF50") // Green with transparency
            style = Paint.Style.FILL
        }
        val y30 = padding + ((100 - 30) / 100f) * chartHeight
        canvas.drawRect(padding, y30, scaledWidth - padding, scaledHeight - padding, oversoldPaint)
        
        // Draw level lines (thin, more visible)
        val levelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.parseColor("#66FFFFFF") // White with transparency for dark theme
            strokeWidth = 1f * scale
            style = Paint.Style.STROKE
        }
        
        // Line 70 (overbought)
        canvas.drawLine(padding, y70, scaledWidth - padding, y70, levelPaint)
        
        // Line 30 (oversold)
        canvas.drawLine(padding, y30, scaledWidth - padding, y30, levelPaint)
        
        // Line 50 (neutral zone)
        val y50 = padding + ((100 - 50) / 100f) * chartHeight
        val midLinePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.parseColor("#44FFFFFF")
            strokeWidth = 0.5f * scale
            style = Paint.Style.STROKE
            pathEffect = DashPathEffect(floatArrayOf(4f * scale, 4f * scale), 0f)
        }
        canvas.drawLine(padding, y50, scaledWidth - padding, y50, midLinePaint)
        
        // Draw chart (thin, clear line, color depends on current RSI)
        val lineColor = when {
            currentRsi < 30 -> Color.parseColor("#66BB6A") // Light green - oversold
            currentRsi > 70 -> Color.parseColor("#EF5350") // Light red - overbought
            else -> Color.parseColor("#42A5F5") // Light blue - normal
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
            // RSI always in range 0-100
            val clampedValue = value.coerceIn(0.0, 100.0)
            val y = padding + ((100f - clampedValue.toFloat()) / 100f) * chartHeight
            
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
            val maxValue = rsiValues.maxOrNull() ?: 0.0
            val minValue = rsiValues.minOrNull() ?: 0.0
            val maxIndex = rsiValues.indexOf(maxValue)
            val minIndex = rsiValues.indexOf(minValue)
            
            // Maximum point (if above 70)
            if (maxValue > 70) {
                val maxX = padding + maxIndex * stepX
                val maxY = padding + ((100f - maxValue.toFloat()) / 100f) * chartHeight
                pointPaint.color = Color.parseColor("#EF5350")
                canvas.drawCircle(maxX, maxY, 3f * scale, pointPaint)
            }
            
            // Minimum point (if below 30)
            if (minValue < 30) {
                val minX = padding + minIndex * stepX
                val minY = padding + ((100f - minValue.toFloat()) / 100f) * chartHeight
                pointPaint.color = Color.parseColor("#66BB6A")
                canvas.drawCircle(minX, minY, 3f * scale, pointPaint)
            }
            
            // Current point (last point) - slightly larger
            val lastIndex = rsiValues.size - 1
            val lastX = padding + lastIndex * stepX
            val lastY = padding + ((100f - currentRsi.coerceIn(0.0, 100.0).toFloat()) / 100f) * chartHeight
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


