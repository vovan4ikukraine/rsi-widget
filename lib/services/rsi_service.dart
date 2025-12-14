import '../models.dart';

/// Service for calculating RSI using Wilder's algorithm
class RsiService {
  /// Calculate RSI for a list of closing prices
  static double? computeRsi(List<double> closes, int period) {
    if (closes.length < period + 1) return null;

    // Calculate initial average values
    double gain = 0, loss = 0;
    for (int i = 1; i <= period; i++) {
      final change = closes[i] - closes[i - 1];
      if (change > 0) {
        gain += change;
      } else {
        loss -= change;
      }
    }

    double au = gain / period;
    double ad = loss / period;

    // Incremental calculation for remaining points
    for (int i = period + 1; i < closes.length; i++) {
      final change = closes[i] - closes[i - 1];
      final u = change > 0 ? change : 0.0;
      final d = change < 0 ? -change : 0.0;

      au = (au * (period - 1) + u) / period;
      ad = (ad * (period - 1) + d) / period;
    }

    if (ad == 0) return 100.0;

    final rs = au / ad;
    final rsi = 100 - (100 / (1 + rs));

    return rsi.clamp(0, 100);
  }

  /// Incremental RSI calculation with state
  static IndicatorResult computeRsiIncremental(
    double currentClose,
    double previousClose,
    IndicatorState? previousState,
    int period,
    int timestamp,
  ) {
    final change = currentClose - previousClose;
    final u = change > 0 ? change : 0.0;
    final d = change < 0 ? -change : 0.0;

    double au, ad;
    if (previousState == null) {
      // First value - use simple average
      au = u;
      ad = d;
    } else {
      // Incremental update using Wilder's formula
      final prevAu = previousState.data['au'] as double? ?? 0.0;
      final prevAd = previousState.data['ad'] as double? ?? 0.0;
      au = (prevAu * (period - 1) + u) / period;
      ad = (prevAd * (period - 1) + d) / period;
    }

    final state = IndicatorState({'au': au, 'ad': ad});
    double rsi;

    if (ad == 0) {
      rsi = 100.0;
    } else {
      final rs = au / ad;
      rsi = 100 - (100 / (1 + rs));
    }

    return IndicatorResult(
      value: rsi.clamp(0, 100),
      state: state,
      timestamp: timestamp,
      close: currentClose,
      indicator: 'rsi',
    );
  }

  /// Determine indicator zone (universal)
  static IndicatorZone getRsiZone(double value, List<double> levels) {
    if (levels.isEmpty) return IndicatorZone.between;

    final lowerLevel = levels.first;
    final upperLevel = levels.length > 1 ? levels[1] : 100.0;

    if (value < lowerLevel) {
      return IndicatorZone.below;
    } else if (value > upperLevel) {
      return IndicatorZone.above;
    } else {
      return IndicatorZone.between;
    }
  }

  /// Check level crossing
  static bool checkCrossUp(
    double currentRsi,
    double previousRsi,
    double level,
  ) {
    return previousRsi <= level && currentRsi > level;
  }

  /// Check downward level crossing
  static bool checkCrossDown(
    double currentRsi,
    double previousRsi,
    double level,
  ) {
    return previousRsi >= level && currentRsi < level;
  }

  /// Check zone entry
  static bool checkEnterZone(
    double currentRsi,
    double previousRsi,
    double lowerLevel,
    double upperLevel,
  ) {
    final wasOutside = previousRsi < lowerLevel || previousRsi > upperLevel;
    final isInside = currentRsi >= lowerLevel && currentRsi <= upperLevel;

    return wasOutside && isInside;
  }

  /// Check zone exit
  static bool checkExitZone(
    double currentRsi,
    double previousRsi,
    double lowerLevel,
    double upperLevel,
  ) {
    final wasInside = previousRsi >= lowerLevel && previousRsi <= upperLevel;
    final isOutside = currentRsi < lowerLevel || currentRsi > upperLevel;

    return wasInside && isOutside;
  }

  /// Check alert triggers
  static List<AlertTrigger> checkAlertTriggers(
    AlertRule rule,
    double currentRsi,
    double previousRsi,
    int timestamp,
  ) {
    final triggers = <AlertTrigger>[];
    final zone = getRsiZone(currentRsi, rule.levels);

    if (rule.mode == 'cross' && rule.levels.isNotEmpty) {
      for (final level in rule.levels) {
        if (checkCrossUp(currentRsi, previousRsi, level)) {
          triggers.add(AlertTrigger(
            ruleId: rule.id,
            symbol: rule.symbol,
            indicatorValue: currentRsi,
            indicator: 'rsi',
            level: level,
            type: AlertType.crossUp,
            zone: zone,
            timestamp: timestamp,
            message: 'RSI crossed level $level upward',
          ));
        }

        if (checkCrossDown(currentRsi, previousRsi, level)) {
          triggers.add(AlertTrigger(
            ruleId: rule.id,
            symbol: rule.symbol,
            indicatorValue: currentRsi,
            indicator: 'rsi',
            level: level,
            type: AlertType.crossDown,
            zone: zone,
            timestamp: timestamp,
            message: 'RSI crossed level $level downward',
          ));
        }
      }
    } else if (rule.mode == 'enter' && rule.levels.length >= 2) {
      if (checkEnterZone(
        currentRsi,
        previousRsi,
        rule.levels[0],
        rule.levels[1],
      )) {
        triggers.add(AlertTrigger(
          ruleId: rule.id,
          symbol: rule.symbol,
          indicatorValue: currentRsi,
          indicator: 'rsi',
          level: rule.levels[1],
          type: AlertType.enterZone,
          zone: zone,
          timestamp: timestamp,
          message: 'RSI entered zone ${rule.levels[0]}-${rule.levels[1]}',
        ));
      }
    } else if (rule.mode == 'exit' && rule.levels.length >= 2) {
      if (checkExitZone(
        currentRsi,
        previousRsi,
        rule.levels[0],
        rule.levels[1],
      )) {
        triggers.add(AlertTrigger(
          ruleId: rule.id,
          symbol: rule.symbol,
          indicatorValue: currentRsi,
          indicator: 'rsi',
          level: rule.levels[1],
          type: AlertType.exitZone,
          zone: zone,
          timestamp: timestamp,
          message: 'RSI exited zone ${rule.levels[0]}-${rule.levels[1]}',
        ));
      }
    }

    return triggers;
  }

  /// Generate sparkline for widget
  static List<double> generateSparkline(List<double> rsiValues, int maxPoints) {
    if (rsiValues.length <= maxPoints) {
      return rsiValues;
    }

    // Take last maxPoints values
    return rsiValues.skip(rsiValues.length - maxPoints).toList();
  }

  /// Normalize RSI for display
  static double normalizeRsi(double rsi) {
    return (rsi * 10).round() / 10; // Round to 1 decimal place
  }
}
