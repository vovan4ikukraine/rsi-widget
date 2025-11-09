import WidgetKit
import SwiftUI

struct RSIWidgetEntry: TimelineEntry {
    let date: Date
    let symbol: String
    let rsi: Double
    let zone: String
    let sparkline: [Double]
    let levels: [Double]
    let timeframe: String
}

struct RSIWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> RSIWidgetEntry {
        RSIWidgetEntry(
            date: Date(),
            symbol: "AAPL",
            rsi: 65.4,
            zone: "above",
            sparkline: [55, 56, 58, 60, 63, 65, 64, 66, 68, 67, 68, 69, 70, 69, 68, 67, 68, 69, 71, 70, 69, 68, 67, 66, 65, 66, 67, 68, 68, 69, 70, 68],
            levels: [30, 70],
            timeframe: "15m"
        )
    }
    
    func getSnapshot(in context: Context, completion: @escaping (RSIWidgetEntry) -> ()) {
        let entry = RSIWidgetEntry(
            date: Date(),
            symbol: "AAPL",
            rsi: 65.4,
            zone: "above",
            sparkline: [55, 56, 58, 60, 63, 65, 64, 66, 68, 67, 68, 69, 70, 69, 68, 67, 68, 69, 71, 70, 69, 68, 67, 66, 65, 66, 67, 68, 68, 69, 70, 68],
            levels: [30, 70],
            timeframe: "15m"
        )
        completion(entry)
    }
    
    func getTimeline(in context: Context, completion: @escaping (Timeline<RSIWidgetEntry>) -> ()) {
        // Create timeline for 60 minutes with updates every 15 minutes
        let currentDate = Date()
        let entries = (0..<4).map { index in
            let entryDate = Calendar.current.date(byAdding: .minute, value: index * 15, to: currentDate)!
            return RSIWidgetEntry(
                date: entryDate,
                symbol: "AAPL",
                rsi: 65.4 + Double.random(in: -5...5),
                zone: "above",
                sparkline: generateSparkline(),
                levels: [30, 70],
                timeframe: "15m"
            )
        }
        
        let timeline = Timeline(entries: entries, policy: .atEnd)
        completion(timeline)
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
            
            // RSI value
            HStack {
                Text(String(format: "%.1f", entry.rsi))
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(zoneColor(entry.zone))
                Spacer()
                zoneIndicator(entry.zone)
            }
            
            // Sparkline
            SparklineView(data: entry.sparkline, levels: entry.levels)
                .frame(height: 20)
        }
        .padding(8)
        .background(Color(.systemBackground))
    }
    
    private func zoneColor(_ zone: String) -> Color {
        switch zone {
        case "below":
            return .red
        case "above":
            return .green
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
                    
                    Rectangle()
                        .fill(Color.red.opacity(0.1))
                        .frame(height: lowerY)
                        .position(x: width / 2, y: lowerY / 2)
                    
                    Rectangle()
                        .fill(Color.green.opacity(0.1))
                        .frame(height: height - upperY)
                        .position(x: width / 2, y: upperY + (height - upperY) / 2)
                }
                
                // RSI line
                Path { path in
                    guard !data.isEmpty else { return }
                    
                    let stepX = width / CGFloat(data.count - 1)
                    
                    for (index, value) in data.enumerated() {
                        let x = CGFloat(index) * stepX
                        let y = height * (1 - CGFloat(value) / maxValue)
                        
                        if index == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(Color.blue, lineWidth: 1.5)
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
        .configurationDisplayName("RSI Widget")
        .description("Display RSI for selected instrument")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct RSIWidget_Previews: PreviewProvider {
    static var previews: some View {
        RSIWidgetEntryView(entry: RSIWidgetEntry(
            date: Date(),
            symbol: "AAPL",
            rsi: 65.4,
            zone: "above",
            sparkline: [55, 56, 58, 60, 63, 65, 64, 66, 68, 67, 68, 69, 70, 69, 68, 67, 68, 69, 71, 70, 69, 68, 67, 66, 65, 66, 67, 68, 68, 69, 70, 68],
            levels: [30, 70],
            timeframe: "15m"
        ))
        .previewContext(WidgetPreviewContext(family: .systemSmall))
    }
}
