import WidgetKit
import SwiftUI

struct RSIWidgetEntry: TimelineEntry {
    let date: Date
    let symbol: String
    let rsi: Double // Keep for backward compatibility
    let indicatorValue: Double // New field for generic indicator value
    let indicator: String // Indicator type: "rsi", "stoch", etc.
    let zone: String
    let sparkline: [Double]
    let levels: [Double]
    let timeframe: String
}

struct RSIWidgetProvider: TimelineProvider {
    // App Group identifier for sharing data between app and widget
    // This should match the App Group ID configured in Xcode capabilities
    private let appGroupId = "group.com.example.rsi_widget"
    
    func placeholder(in context: Context) -> RSIWidgetEntry {
        RSIWidgetEntry(
            date: Date(),
            symbol: "AAPL",
            rsi: 65.4,
            indicatorValue: 65.4,
            indicator: "rsi",
            zone: "above",
            sparkline: [55, 56, 58, 60, 63, 65, 64, 66, 68, 67, 68, 69, 70, 69, 68, 67, 68, 69, 71, 70, 69, 68, 67, 66, 65, 66, 67, 68, 68, 69, 70, 68],
            levels: [30, 70],
            timeframe: "15m"
        )
    }
    
    func getSnapshot(in context: Context, completion: @escaping (RSIWidgetEntry) -> ()) {
        let entry = loadWidgetData() ?? placeholder(in: context)
        completion(entry)
    }
    
    func getTimeline(in context: Context, completion: @escaping (Timeline<RSIWidgetEntry>) -> ()) {
        let currentDate = Date()
        
        // Load current data
        let currentEntry = loadWidgetData() ?? placeholder(in: context)
        
        // Create entries for the next hour (updates every 15 minutes)
        var entries: [RSIWidgetEntry] = [currentEntry]
        
        for i in 1..<4 {
            if let futureDate = Calendar.current.date(byAdding: .minute, value: i * 15, to: currentDate) {
                // Use same data for future entries (or reload if needed)
                let futureEntry = RSIWidgetEntry(
                    date: futureDate,
                    symbol: currentEntry.symbol,
                    rsi: currentEntry.rsi,
                    indicatorValue: currentEntry.indicatorValue,
                    indicator: currentEntry.indicator,
                    zone: currentEntry.zone,
                    sparkline: currentEntry.sparkline,
                    levels: currentEntry.levels,
                    timeframe: currentEntry.timeframe
                )
                entries.append(futureEntry)
            }
        }
        
        let timeline = Timeline(entries: entries, policy: .atEnd)
        completion(timeline)
    }
    
    private func loadWidgetData() -> RSIWidgetEntry? {
        guard let sharedDefaults = UserDefaults(suiteName: appGroupId) else {
            // Fallback to standard UserDefaults if App Group not available
            let defaults = UserDefaults.standard
            return loadEntry(from: defaults)
        }
        
        return loadEntry(from: sharedDefaults)
    }
    
    private func loadEntry(from defaults: UserDefaults) -> RSIWidgetEntry? {
        // Try to load watchlist data JSON
        guard let watchlistDataJson = defaults.string(forKey: "watchlist_data"),
              let data = watchlistDataJson.data(using: .utf8),
              let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let firstItem = jsonArray.first else {
            return nil
        }
        
        let symbol = firstItem["symbol"] as? String ?? "AAPL"
        let indicatorValue = (firstItem["indicatorValue"] as? Double) ?? (firstItem["rsi"] as? Double) ?? 50.0
        let rsi = (firstItem["rsi"] as? Double) ?? indicatorValue
        let indicator = firstItem["indicator"] as? String ?? "rsi"
        let timeframe = defaults.string(forKey: "timeframe") ?? "15m"
        
        // Load indicator values for sparkline
        var sparkline: [Double] = []
        if let indicatorValues = firstItem["indicatorValues"] as? [Double] {
            sparkline = indicatorValues
        } else if let rsiValues = firstItem["rsiValues"] as? [Double] {
            sparkline = rsiValues
        }
        
        // Determine levels based on indicator type
        let levels: [Double]
        if indicator.lowercased() == "stoch" {
            levels = [20, 80] // Stochastic levels
        } else {
            levels = [30, 70] // Default RSI levels
        }
        
        // Determine zone based on indicator value and levels
        let zone: String
        if indicatorValue < levels[0] {
            zone = "below"
        } else if indicatorValue > levels[1] {
            zone = "above"
        } else {
            zone = "between"
        }
        
        return RSIWidgetEntry(
            date: Date(),
            symbol: symbol,
            rsi: rsi,
            indicatorValue: indicatorValue,
            indicator: indicator,
            zone: zone,
            sparkline: sparkline.isEmpty ? generateSparkline() : sparkline,
            levels: levels,
            timeframe: timeframe
        )
    }
    
    private func generateSparkline() -> [Double] {
        return (0..<32).map { _ in Double.random(in: 20...80) }
    }
}

struct RSIWidgetEntryView: View {
    var entry: RSIWidgetEntry
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header with symbol
            HStack {
                Text(entry.symbol)
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                Spacer()
                Text(entry.timeframe)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            // Indicator value
            HStack {
                Text(String(format: "%.1f", entry.indicatorValue))
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(zoneColor(entry.zone, indicator: entry.indicator))
                Spacer()
                zoneIndicator(entry.zone)
            }
            
            // Sparkline
            SparklineView(data: entry.sparkline, levels: entry.levels, indicator: entry.indicator, currentValue: entry.indicatorValue)
                .frame(height: 20)
        }
        .padding(8)
        .background(Color(.systemBackground))
    }
    
    private func zoneColor(_ zone: String, indicator: String) -> Color {
        switch zone {
        case "below":
            return indicator.lowercased() == "stoch" ? .green : .green // Oversold is green
        case "above":
            return indicator.lowercased() == "stoch" ? .red : .red // Overbought is red
        default:
            return .blue
        }
    }
    
    private func zoneIndicator(_ zone: String) -> some View {
        let (icon, color) = zoneIconAndColor(zone)
        return Image(systemName: icon)
            .foregroundColor(color)
            .font(.caption)
    }
    
    private func zoneIconAndColor(_ zone: String) -> (String, Color) {
        switch zone {
        case "below":
            return ("arrow.down.circle.fill", .red)
        case "above":
            return ("arrow.up.circle.fill", .green)
        default:
            return ("minus.circle.fill", .blue)
        }
    }
}

struct SparklineView: View {
    let data: [Double]
    let levels: [Double]
    let indicator: String
    let currentValue: Double
    
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let maxValue = 100.0
            let minValue = 0.0
            
            ZStack {
                // Zone backgrounds
                if levels.count >= 2 {
                    let lowerY = height * (1 - CGFloat(levels[0]) / maxValue)
                    let upperY = height * (1 - CGFloat(levels[1]) / maxValue)
                    
                    // Oversold zone (below lower level) - green
                    Rectangle()
                        .fill(Color.green.opacity(0.1))
                        .frame(height: height - lowerY)
                        .position(x: width / 2, y: lowerY + (height - lowerY) / 2)
                    
                    // Overbought zone (above upper level) - red
                    Rectangle()
                        .fill(Color.red.opacity(0.1))
                        .frame(height: upperY)
                        .position(x: width / 2, y: upperY / 2)
                }
                
                // Indicator line with color based on current value
                let lineColor: Color
                if currentValue < levels[0] {
                    lineColor = .green // Oversold
                } else if currentValue > levels[1] {
                    lineColor = .red // Overbought
                } else {
                    lineColor = .blue // Normal
                }
                
                Path { path in
                    guard !data.isEmpty else { return }
                    
                    let stepX = width / CGFloat(max(data.count - 1, 1))
                    
                    for (index, value) in data.enumerated() {
                        let x = CGFloat(index) * stepX
                        let clampedValue = min(max(value, 0), 100)
                        let y = height * (1 - CGFloat(clampedValue) / maxValue)
                        
                        if index == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(lineColor, lineWidth: 1.5)
            }
        }
    }
}

struct RSIWidget: Widget {
    let kind: String = "RSIWidget"
    
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RSIWidgetProvider()) { entry in
            RSIWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Indicator Widget")
        .description("Display technical indicator for selected instrument")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct RSIWidget_Previews: PreviewProvider {
    static var previews: some View {
        RSIWidgetEntryView(entry: RSIWidgetEntry(
            date: Date(),
            symbol: "AAPL",
            rsi: 65.4,
            indicatorValue: 65.4,
            indicator: "rsi",
            zone: "above",
            sparkline: [55, 56, 58, 60, 63, 65, 64, 66, 68, 67, 68, 69, 70, 69, 68, 67, 68, 69, 71, 70, 69, 68, 67, 66, 65, 66, 67, 68, 68, 69, 70, 68],
            levels: [30, 70],
            timeframe: "15m"
        ))
        .previewContext(WidgetPreviewContext(family: .systemSmall))
    }
}
