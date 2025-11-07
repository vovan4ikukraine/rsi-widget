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
 * RemoteViewsService для отображения элементов списка в виджете
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
        val change: Double,
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
                    val change = item.optDouble("change", 0.0)
                    
                    // Парсим массив RSI значений для графика
                    val rsiValuesArray = item.optJSONArray("rsiValues")
                    val rsiValues = mutableListOf<Double>()
                    if (rsiValuesArray != null) {
                        for (j in 0 until rsiValuesArray.length()) {
                            rsiValues.add(rsiValuesArray.getDouble(j))
                        }
                    }
                    
                    items.add(WidgetItem(symbol, rsi, price, change, rsiValues))
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
        
        // Устанавливаем данные
        views.setTextViewText(R.id.widget_symbol, item.symbol)
        views.setTextViewText(R.id.widget_rsi, String.format("%.2f", item.rsi))
        views.setTextViewText(R.id.widget_price, String.format("%.2f", item.price))
        
        // Устанавливаем фон для RSI badge (используем drawable для скругленных углов)
        views.setInt(R.id.widget_rsi, "setBackgroundResource", R.drawable.widget_rsi_badge_background)
        
        // Устанавливаем цвет текста RSI в зависимости от значения
        val rsiTextColor = when {
            item.rsi < 30 -> Color.parseColor("#66BB6A") // Зеленый для перепроданности
            item.rsi > 70 -> Color.parseColor("#EF5350") // Красный для перекупленности
            else -> Color.parseColor("#42A5F5") // Синий для нормального состояния
        }
        views.setTextColor(R.id.widget_rsi, rsiTextColor)
        
        // Цвет изменения цены (современные цвета для темной темы)
        val changeColor = if (item.change >= 0) {
            Color.parseColor("#66BB6A")
        } else {
            Color.parseColor("#EF5350")
        }
        val changeText = if (item.change >= 0) "+${String.format("%.2f", item.change)}" 
                        else String.format("%.2f", item.change)
        views.setTextViewText(R.id.widget_change, changeText)
        views.setTextColor(R.id.widget_change, changeColor)
        
        // Создаем график RSI как Bitmap (увеличиваем размер для лучшей видимости)
        if (item.rsiValues.isNotEmpty()) {
            Log.d(TAG, "Creating chart for ${item.symbol} at position $position: ${item.rsiValues.size} values, current RSI: ${item.rsi}")
            Log.d(TAG, "Chart values range: min=${item.rsiValues.minOrNull()}, max=${item.rsiValues.maxOrNull()}")
            val chartBitmap = createChartBitmap(item.rsiValues, item.rsi, 600, 80)
            views.setImageViewBitmap(R.id.widget_chart, chartBitmap)
            Log.d(TAG, "Chart bitmap created and set for ${item.symbol}")
        } else {
            Log.w(TAG, "No RSI values for ${item.symbol}, skipping chart")
            // Создаем пустой битмап с полупрозрачным фоном
            val emptyBitmap = Bitmap.createBitmap(600, 80, Bitmap.Config.ARGB_8888)
            emptyBitmap.eraseColor(Color.parseColor("#E01E1E1E"))
            views.setImageViewBitmap(R.id.widget_chart, emptyBitmap)
        }
        
        // Намерение для открытия приложения при клике
        val fillInIntent = Intent().apply {
            putExtra("symbol", item.symbol)
        }
        views.setOnClickFillInIntent(R.id.widget_item_root, fillInIntent)
        
        return views
    }
    
    private fun createChartBitmap(rsiValues: List<Double>, currentRsi: Double, width: Int, height: Int): Bitmap {
        // Увеличиваем разрешение для лучшей четкости (2x для Retina)
        val scale = 2f
        val scaledWidth = (width * scale).toInt()
        val scaledHeight = (height * scale).toInt()
        
        val bitmap = Bitmap.createBitmap(scaledWidth, scaledHeight, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        
        // Полупрозрачный темный фон для современного вида
        canvas.drawColor(Color.parseColor("#E01E1E1E"))
        
        if (rsiValues.isEmpty()) {
            // Масштабируем обратно для отображения
            return Bitmap.createScaledBitmap(bitmap, width, height, true)
        }
        
        // Используем фиксированный масштаб 0-100 для RSI
        val padding = 8f * scale
        val chartWidth = scaledWidth - padding * 2
        val chartHeight = scaledHeight - padding * 2
        
        // Зона перекупленности (выше 70) - темно-красная с прозрачностью
        val overboughtPaint = Paint().apply {
            color = Color.parseColor("#33F44336") // Красный с прозрачностью
            style = Paint.Style.FILL
        }
        val y70 = padding + ((100 - 70) / 100f) * chartHeight
        canvas.drawRect(padding, padding, scaledWidth - padding, y70, overboughtPaint)
        
        // Зона перепроданности (ниже 30) - темно-зеленая с прозрачностью
        val oversoldPaint = Paint().apply {
            color = Color.parseColor("#334CAF50") // Зеленый с прозрачностью
            style = Paint.Style.FILL
        }
        val y30 = padding + ((100 - 30) / 100f) * chartHeight
        canvas.drawRect(padding, y30, scaledWidth - padding, scaledHeight - padding, oversoldPaint)
        
        // Рисуем линии уровней (тонкие, более заметные)
        val levelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.parseColor("#66FFFFFF") // Белый с прозрачностью для темной темы
            strokeWidth = 1f * scale
            style = Paint.Style.STROKE
        }
        
        // Линия 70 (перекупленность)
        canvas.drawLine(padding, y70, scaledWidth - padding, y70, levelPaint)
        
        // Линия 30 (перепроданность)
        canvas.drawLine(padding, y30, scaledWidth - padding, y30, levelPaint)
        
        // Линия 50 (нейтральная зона)
        val y50 = padding + ((100 - 50) / 100f) * chartHeight
        val midLinePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.parseColor("#44FFFFFF")
            strokeWidth = 0.5f * scale
            style = Paint.Style.STROKE
            pathEffect = DashPathEffect(floatArrayOf(4f * scale, 4f * scale), 0f)
        }
        canvas.drawLine(padding, y50, scaledWidth - padding, y50, midLinePaint)
        
        // Рисуем график (тонкая, четкая линия, цвет зависит от текущего RSI)
        val lineColor = when {
            currentRsi < 30 -> Color.parseColor("#66BB6A") // Светло-зеленый - перепроданность
            currentRsi > 70 -> Color.parseColor("#EF5350") // Светло-красный - перекупленность
            else -> Color.parseColor("#42A5F5") // Светло-синий - норма
        }
        
        val linePaint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG).apply {
            color = lineColor
            style = Paint.Style.STROKE
            strokeWidth = 2f * scale // Тонкая линия (эквивалент 1px при масштабе)
            strokeCap = Paint.Cap.ROUND
            strokeJoin = Paint.Join.ROUND
            isAntiAlias = true
        }
        
        val path = Path()
        val stepX = if (rsiValues.size > 1) chartWidth / (rsiValues.size - 1) else 0f
        
        rsiValues.forEachIndexed { index, value ->
            val x = padding + index * stepX
            // RSI всегда в диапазоне 0-100
            val clampedValue = value.coerceIn(0.0, 100.0)
            val y = padding + ((100f - clampedValue.toFloat()) / 100f) * chartHeight
            
            if (index == 0) {
                path.moveTo(x, y)
            } else {
                path.lineTo(x, y)
            }
        }
        
        canvas.drawPath(path, linePaint)
        
        // Рисуем точки на экстремумах (максимумы и минимумы) - более тонкие
        val pointPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.FILL
        }
        
        if (rsiValues.isNotEmpty()) {
            val maxValue = rsiValues.maxOrNull() ?: 0.0
            val minValue = rsiValues.minOrNull() ?: 0.0
            val maxIndex = rsiValues.indexOf(maxValue)
            val minIndex = rsiValues.indexOf(minValue)
            
            // Точка максимума (если выше 70)
            if (maxValue > 70) {
                val maxX = padding + maxIndex * stepX
                val maxY = padding + ((100f - maxValue.toFloat()) / 100f) * chartHeight
                pointPaint.color = Color.parseColor("#EF5350")
                canvas.drawCircle(maxX, maxY, 3f * scale, pointPaint)
            }
            
            // Точка минимума (если ниже 30)
            if (minValue < 30) {
                val minX = padding + minIndex * stepX
                val minY = padding + ((100f - minValue.toFloat()) / 100f) * chartHeight
                pointPaint.color = Color.parseColor("#66BB6A")
                canvas.drawCircle(minX, minY, 3f * scale, pointPaint)
            }
            
            // Текущая точка (последняя точка) - чуть больше
            val lastIndex = rsiValues.size - 1
            val lastX = padding + lastIndex * stepX
            val lastY = padding + ((100f - currentRsi.coerceIn(0.0, 100.0).toFloat()) / 100f) * chartHeight
            pointPaint.color = lineColor
            // Рисуем обводку для лучшей видимости
            pointPaint.style = Paint.Style.FILL
            canvas.drawCircle(lastX, lastY, 3.5f * scale, pointPaint)
            pointPaint.color = Color.parseColor("#E01E1E1E")
            canvas.drawCircle(lastX, lastY, 2f * scale, pointPaint)
        }
        
        // Масштабируем обратно для отображения (с фильтрацией для четкости)
        return Bitmap.createScaledBitmap(bitmap, width, height, true)
    }
    
    override fun getLoadingView(): RemoteViews? = null
    
    override fun getViewTypeCount(): Int = 1
    
    override fun getItemId(position: Int): Long = position.toLong()
    
    override fun hasStableIds(): Boolean = true
}


