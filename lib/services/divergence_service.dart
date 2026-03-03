import '../models/divergence.dart';
import '../models.dart';

/// Detects divergences between price and indicator
class DivergenceService {
  /// Lookback for local extrema (bars on each side)
  static const int _lookback = 3;

  /// Minimum bars between two extrema to consider a divergence
  static const int _minBarsBetween = 5;

  /// Minimum data length for detection
  static const int _minLength = _lookback * 2 + _minBarsBetween;

  /// Detect divergences from indicator results (avoids duplicate list allocation)
  static List<Divergence> detectFromResults(List<IndicatorResult> results) {
    if (results.length < _minLength) return [];
    final values = results.map((r) => r.value).toList();
    final prices = results.map((r) => r.close).toList();
    return detect(values, prices);
  }

  /// Detect divergences in indicator vs price
  /// [indicatorValues] - indicator values (RSI, Stoch, etc.)
  /// [prices] - close prices, must align with indicatorValues
  static List<Divergence> detect(
    List<double> indicatorValues,
    List<double> prices,
  ) {
    if (indicatorValues.length != prices.length ||
        indicatorValues.length < _minLength) {
      return [];
    }

    final lows = _findLocalExtrema(indicatorValues, isMinimum: true);
    final highs = _findLocalExtrema(indicatorValues, isMinimum: false);

    final divergences = <Divergence>[];

    // Bullish: price LL, indicator HL (successive lows)
    for (int i = 0; i < lows.length - 1; i++) {
      final a = lows[i];
      final b = lows[i + 1];
      if (b - a < _minBarsBetween) continue;
      if (prices[b] < prices[a] && indicatorValues[b] > indicatorValues[a]) {
        divergences.add(Divergence(
          startIndex: a,
          endIndex: b,
          type: DivergenceType.bullish,
        ));
      }
    }

    // Bearish: price HH, indicator LH (successive highs)
    for (int i = 0; i < highs.length - 1; i++) {
      final a = highs[i];
      final b = highs[i + 1];
      if (b - a < _minBarsBetween) continue;
      if (prices[b] > prices[a] && indicatorValues[b] < indicatorValues[a]) {
        divergences.add(Divergence(
          startIndex: a,
          endIndex: b,
          type: DivergenceType.bearish,
        ));
      }
    }

    return divergences;
  }

  static List<int> _findLocalExtrema(
    List<double> values, {
    required bool isMinimum,
  }) {
    final result = <int>[];
    for (int i = _lookback; i < values.length - _lookback; i++) {
      final v = values[i];
      bool isExtremum = true;
      for (int j = 1; j <= _lookback; j++) {
        if (isMinimum
            ? v >= values[i - j] || v >= values[i + j]
            : v <= values[i - j] || v <= values[i + j]) {
          isExtremum = false;
          break;
        }
      }
      if (isExtremum) result.add(i);
    }
    return result;
  }
}
