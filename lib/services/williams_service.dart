import '../models.dart';

/// Service for calculating Williams %R (Williams Percent Range)
class WilliamsService {
  /// Calculate Williams %R for a list of candles
  /// Williams %R = ((Highest High - Close) / (Highest High - Lowest Low)) × -100
  /// Values range from -100 to 0
  static List<double> computeWilliams(
    List<double> highs,
    List<double> lows,
    List<double> closes,
    int period,
  ) {
    if (highs.length != lows.length || highs.length != closes.length) {
      return [];
    }
    if (highs.length < period) {
      return [];
    }

    final williamsValues = <double>[];

    // Calculate Williams %R starting from index period - 1
    // %R[i] = ((Highest High - Close[i]) / (Highest High - Lowest Low)) × -100
    // where Highest High and Lowest Low are taken from period [i - period + 1, i]
    for (int i = period - 1; i < highs.length; i++) {
      // Get high and low values for the period
      final periodHighs = highs.sublist(i - period + 1, i + 1);
      final periodLows = lows.sublist(i - period + 1, i + 1);
      final close = closes[i];

      final highestHigh = periodHighs.reduce((a, b) => a > b ? a : b);
      final lowestLow = periodLows.reduce((a, b) => a < b ? a : b);

      double williams;
      if (highestHigh == lowestLow) {
        // Avoid division by zero - use -50 as neutral value
        williams = -50.0;
      } else {
        williams = ((highestHigh - close) / (highestHigh - lowestLow)) * -100.0;
        williams = williams.clamp(-100.0, 0.0);
      }

      williamsValues.add(williams);
    }

    return williamsValues;
  }

  /// Calculate Williams %R history for a list of candles
  /// Returns results aligned with input candles (like RSI does)
  static List<WilliamsResult> computeWilliamsHistory(
    List<Map<String, dynamic>> candles,
    int period,
  ) {
    if (candles.length < period) {
      return [];
    }

    // Extract and validate data
    final highs = <double>[];
    final lows = <double>[];
    final closes = <double>[];
    final timestamps = <int>[];

    for (final candle in candles) {
      final high = (candle['high'] as num?)?.toDouble();
      final low = (candle['low'] as num?)?.toDouble();
      final close = (candle['close'] as num?)?.toDouble();
      final timestamp = (candle['timestamp'] as num?)?.toInt();

      // Skip invalid candles
      if (high == null ||
          low == null ||
          close == null ||
          timestamp == null ||
          high < low ||
          high <= 0 ||
          low <= 0) {
        continue;
      }

      highs.add(high);
      lows.add(low);
      closes.add(close);
      timestamps.add(timestamp);
    }

    // Check if we have enough valid data
    if (highs.length < period) {
      return [];
    }

    // Calculate Williams %R values
    // williamsValues[i] corresponds to candle at index (period - 1 + i)
    final williamsValues = computeWilliams(highs, lows, closes, period);
    if (williamsValues.isEmpty) {
      return [];
    }

    // Build results aligned with filtered candles
    final results = <WilliamsResult>[];
    final startIndex = period - 1; // First candle index with Williams %R

    for (int i = 0; i < williamsValues.length; i++) {
      final candleIndex = startIndex + i;
      if (candleIndex >= highs.length) break;

      results.add(WilliamsResult(
        williams: williamsValues[i],
        timestamp: timestamps[candleIndex],
        close: closes[candleIndex],
      ));
    }

    return results;
  }

  /// Determine Williams %R zone
  /// Williams %R is oversold when < -80 and overbought when > -20
  static IndicatorZone getWilliamsZone(double williams, List<double> levels) {
    if (levels.length < 2) {
      // Default levels: -80 (oversold) and -20 (overbought)
      if (williams < -80) {
        return IndicatorZone.below; // Oversold
      } else if (williams > -20) {
        return IndicatorZone.above; // Overbought
      } else {
        return IndicatorZone.between;
      }
    }

    final lowerLevel = levels[0]; // Oversold level (typically -80)
    final upperLevel = levels[1]; // Overbought level (typically -20)

    // Note: Williams %R values are negative, so we compare differently
    // Lower values (more negative) = oversold
    // Higher values (less negative) = overbought
    if (williams < lowerLevel) {
      return IndicatorZone.below; // Oversold
    } else if (williams > upperLevel) {
      return IndicatorZone.above; // Overbought
    } else {
      return IndicatorZone.between;
    }
  }
}

/// Result of Williams %R calculation
class WilliamsResult {
  final double williams;
  final int timestamp;
  final double close;

  WilliamsResult({
    required this.williams,
    required this.timestamp,
    required this.close,
  });

  /// Convert to IndicatorResult
  IndicatorResult toIndicatorResult() {
    return IndicatorResult(
      value: williams,
      state: IndicatorState({'williams': williams}),
      timestamp: timestamp,
      close: close,
      indicator: 'williams',
    );
  }
}









