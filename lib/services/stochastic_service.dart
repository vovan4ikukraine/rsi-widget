import '../models.dart';

/// Service for calculating Stochastic Oscillator (%K and %D)
class StochasticService {
  /// Calculate Stochastic %K for a list of candles
  static List<double> computeK(
    List<double> highs,
    List<double> lows,
    List<double> closes,
    int kPeriod,
  ) {
    if (highs.length != lows.length || highs.length != closes.length) {
      return [];
    }
    if (highs.length < kPeriod) {
      return [];
    }

    final kValues = <double>[];

    // Calculate %K starting from index kPeriod - 1
    // %K[i] = ((Close[i] - Lowest Low) / (Highest High - Lowest Low)) × 100
    // where Highest High and Lowest Low are taken from period [i - kPeriod + 1, i]
    for (int i = kPeriod - 1; i < highs.length; i++) {
      // Get high and low values for the period
      final periodHighs = highs.sublist(i - kPeriod + 1, i + 1);
      final periodLows = lows.sublist(i - kPeriod + 1, i + 1);
      final close = closes[i];

      final highestHigh = periodHighs.reduce((a, b) => a > b ? a : b);
      final lowestLow = periodLows.reduce((a, b) => a < b ? a : b);

      double k;
      if (highestHigh == lowestLow) {
        // Avoid division by zero - use 50 as neutral value
        k = 50.0;
      } else {
        k = ((close - lowestLow) / (highestHigh - lowestLow)) * 100.0;
        k = k.clamp(0, 100);
      }

      kValues.add(k);
    }

    return kValues;
  }

  /// Calculate Stochastic %D (simple moving average of %K)
  static List<double> computeD(List<double> kValues, int dPeriod) {
    if (kValues.length < dPeriod) {
      return [];
    }

    final dValues = <double>[];

    // Calculate %D as SMA of %K
    // %D[i] = SMA(%K[i - dPeriod + 1..i], dPeriod)
    for (int i = dPeriod - 1; i < kValues.length; i++) {
      final periodValues = kValues.sublist(i - dPeriod + 1, i + 1);
      final d = periodValues.reduce((a, b) => a + b) / dPeriod;
      dValues.add(d.clamp(0, 100));
    }

    return dValues;
  }

  /// Calculate full Stochastic (%K and %D) for a list of candles
  static StochasticResult computeStochastic(
    List<double> highs,
    List<double> lows,
    List<double> closes,
    int kPeriod,
    int dPeriod,
    int timestamp,
    double currentClose,
  ) {
    final kValues = computeK(highs, lows, closes, kPeriod);
    if (kValues.isEmpty) {
      throw ArgumentError('Not enough data for Stochastic calculation');
    }

    final dValues = computeD(kValues, dPeriod);
    if (dValues.isEmpty) {
      throw ArgumentError('Not enough data for %D calculation');
    }

    final currentK = kValues.last;
    final currentD = dValues.last;

    return StochasticResult(
      k: currentK,
      d: currentD,
      timestamp: timestamp,
      close: currentClose,
    );
  }

  /// Calculate Stochastic history for a list of candles
  /// Returns results aligned with input candles (like RSI does)
  /// Supports Slow Stochastic with parameters: kPeriod, slowPeriod, dPeriod, smoothPeriod
  static List<StochasticResult> computeStochasticHistory(
    List<Map<String, dynamic>> candles,
    int kPeriod,
    int dPeriod, {
    int? slowPeriod,
    int? smoothPeriod,
  }) {
    // Use Slow Stochastic if slowPeriod is provided
    final useSlowStochastic = slowPeriod != null && slowPeriod > 1;
    final slowPeriodValue = slowPeriod ?? 1;
    final minDataRequired = useSlowStochastic
        ? kPeriod + slowPeriodValue + dPeriod - 2
        : kPeriod + dPeriod - 1;
    
    if (candles.length < minDataRequired) {
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
    if (highs.length < minDataRequired) {
      return [];
    }

    // Step 1: Calculate raw %K values (Fast Stochastic %K)
    // rawKValues[i] corresponds to candle at index (kPeriod - 1 + i)
    final rawKValues = computeK(highs, lows, closes, kPeriod);
    if (rawKValues.isEmpty) {
      return [];
    }

    // Step 2: Apply Slow Stochastic smoothing if needed
    // Smooth %K with SMA(slowPeriod) to get Slow Stochastic %K
    final kValues = useSlowStochastic
        ? computeD(rawKValues, slowPeriodValue)
        : rawKValues;

    if (kValues.isEmpty) {
      return [];
    }

    // Step 3: Calculate %D values as SMA of (smoothed) %K
    // dValues[i] = SMA(kValues[i - dPeriod + 1..i]) for i >= dPeriod - 1
    var dValues = computeD(kValues, dPeriod);
    if (dValues.isEmpty) {
      return [];
    }

    // Step 4: Apply additional smoothing to %D if smoothPeriod is provided
    if (smoothPeriod != null && smoothPeriod > 1) {
      dValues = computeD(dValues, smoothPeriod);
      if (dValues.isEmpty) {
        return [];
      }
    }

    // Build results aligned with filtered candles
    // For Slow Stochastic with smoothPeriod:
    // - rawKValues[i] corresponds to candle at index (kPeriod - 1 + i)
    // - kValues[i] (smoothed %K) = SMA(rawKValues[i - slowPeriod + 1..i])
    //   kValues[i] corresponds to rawKValues[slowPeriod - 1 + i], which corresponds to candle at index (kPeriod - 1 + slowPeriod - 1 + i) = (kPeriod + slowPeriod - 2 + i)
    // - dValues[i] (before smoothing) = SMA(kValues[i - dPeriod + 1..i])
    //   dValues[i] corresponds to kValues[dPeriod - 1 + i], which corresponds to candle at index (kPeriod + slowPeriod - 2 + dPeriod - 1 + i) = (kPeriod + slowPeriod + dPeriod - 3 + i)
    // - dValues[i] (after smoothing) = SMA(dValues[i - smoothPeriod + 1..i])
    //   final dValues[i] corresponds to dValues[smoothPeriod - 1 + i], which corresponds to candle at index (kPeriod + slowPeriod + dPeriod - 3 + smoothPeriod - 1 + i) = (kPeriod + slowPeriod + dPeriod + smoothPeriod - 4 + i)
    
    // For Fast Stochastic:
    // - kValues[i] corresponds to candle at index (kPeriod - 1 + i)
    // - dValues[i] corresponds to kValues[dPeriod - 1 + i], which corresponds to candle at index (kPeriod - 1 + dPeriod - 1 + i) = (kPeriod + dPeriod - 2 + i)
    
    final results = <StochasticResult>[];
    
    // Calculate offsets
    final slowOffset = useSlowStochastic ? (slowPeriodValue - 1) : 0;
    final smoothOffset = (smoothPeriod != null && smoothPeriod > 1) ? (smoothPeriod - 1) : 0;
    
    // First candle index that has both %K and %D
    // For Fast Stochastic: dValues[0] corresponds to rawKValues[dPeriod - 1], which corresponds to candle at index (kPeriod - 1) + (dPeriod - 1) = kPeriod + dPeriod - 2
    // For Slow Stochastic: add slowOffset and smoothOffset for smoothing delays
    // Note: Previously used kPeriod + dPeriod - 1, but that was off by 1. Correct value is kPeriod + dPeriod - 2.
    final firstCandleIndex = kPeriod + slowOffset + dPeriod - 2 + smoothOffset;

    for (int i = 0; i < dValues.length; i++) {
      final candleIndex = firstCandleIndex + i;
      if (candleIndex >= highs.length) break;

      // The %K value that corresponds to this %D value
      // dValues[i] (after all smoothing) corresponds to:
      // - For Slow Stochastic: kValues[dPeriod - 1 + smoothOffset + i]
      // - For Fast Stochastic: kValues[dPeriod - 1 + smoothOffset + i]
      final kIndexInSmoothed = dPeriod - 1 + smoothOffset + i;
      if (kIndexInSmoothed >= kValues.length) break;

      // For display, use smoothed %K for Slow Stochastic (which is what Yahoo Finance shows)
      // For Fast Stochastic, use raw %K
      final displayK = useSlowStochastic 
          ? kValues[kIndexInSmoothed]  // Use smoothed %K for Slow Stochastic
          : (kIndexInSmoothed < rawKValues.length 
              ? rawKValues[kIndexInSmoothed] 
              : kValues[kIndexInSmoothed]);

      results.add(StochasticResult(
        k: displayK,
        d: dValues[i],
        timestamp: timestamps[candleIndex],
        close: closes[candleIndex],
      ));
    }

    return results;
  }

  /// Determine Stochastic zone (using %K value)
  static IndicatorZone getStochasticZone(double k, List<double> levels) {
    if (levels.isEmpty) return IndicatorZone.between;

    final lowerLevel = levels.first;
    final upperLevel = levels.length > 1 ? levels[1] : 100.0;

    if (k < lowerLevel) {
      return IndicatorZone.below;
    } else if (k > upperLevel) {
      return IndicatorZone.above;
    } else {
      return IndicatorZone.between;
    }
  }
}

/// Result of Stochastic calculation
class StochasticResult {
  final double k; // %K value
  final double d; // %D value
  final int timestamp;
  final double close;

  StochasticResult({
    required this.k,
    required this.d,
    required this.timestamp,
    required this.close,
  });

  /// Convert to IndicatorResult format
  /// Use %D as main value - it's smoother and provides clearer signals
  /// %D is the signal line (SMA of %K) and is commonly used as the primary indicator
  IndicatorResult toIndicatorResult() {
    return IndicatorResult(
      value: d, // Use %D as main value - smoother signal line
      state: IndicatorState({'k': k, 'd': d}),
      timestamp: timestamp,
      close: close,
      indicator: 'stoch',
    );
  }
}
