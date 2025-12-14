import '../models.dart';

/// Service for calculating Stochastic Oscillator (%K and %D)
class StochasticService {
  /// Calculate Stochastic %K for a list of candles
  static List<double> computeK(
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

    final kValues = <double>[];

    for (int i = period - 1; i < highs.length; i++) {
      final periodHighs = highs.sublist(i - period + 1, i + 1);
      final periodLows = lows.sublist(i - period + 1, i + 1);
      final close = closes[i];

      final highestHigh = periodHighs.reduce((a, b) => a > b ? a : b);
      final lowestLow = periodLows.reduce((a, b) => a < b ? a : b);

      if (highestHigh == lowestLow) {
        kValues.add(50.0);
      } else {
        final k = ((close - lowestLow) / (highestHigh - lowestLow)) * 100.0;
        kValues.add(k.clamp(0, 100));
      }
    }

    return kValues;
  }

  /// Calculate Stochastic %D (smoothed %K)
  static List<double> computeD(List<double> kValues, int dPeriod) {
    if (kValues.length < dPeriod) {
      return [];
    }

    final dValues = <double>[];

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
  static List<StochasticResult> computeStochasticHistory(
    List<Map<String, dynamic>> candles,
    int kPeriod,
    int dPeriod,
  ) {
    if (candles.length < kPeriod + dPeriod - 1) {
      return [];
    }

    final highs = candles.map((c) => c['high'] as double).toList();
    final lows = candles.map((c) => c['low'] as double).toList();
    final closes = candles.map((c) => c['close'] as double).toList();
    final timestamps = candles.map((c) => c['timestamp'] as int).toList();

    final kValues = computeK(highs, lows, closes, kPeriod);
    if (kValues.isEmpty) {
      return [];
    }

    final dValues = computeD(kValues, dPeriod);
    if (dValues.isEmpty) {
      return [];
    }

    final results = <StochasticResult>[];
    final offset = kPeriod + dPeriod - 2; // Index offset for aligned data

    for (int i = 0; i < dValues.length; i++) {
      final idx = offset + i;
      if (idx < candles.length) {
        results.add(StochasticResult(
          k: kValues[i + dPeriod - 1],
          d: dValues[i],
          timestamp: timestamps[idx],
          close: closes[idx],
        ));
      }
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
  IndicatorResult toIndicatorResult() {
    return IndicatorResult(
      value: k, // Use %K as main value
      state: IndicatorState({'k': k, 'd': d}),
      timestamp: timestamp,
      close: close,
      indicator: 'stoch',
    );
  }
}
