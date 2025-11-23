import 'package:flutter/material.dart';
import '../models.dart';
import '../models/indicator_type.dart';
import 'rsi_service.dart';
import 'stochastic_service.dart';

/// Universal service for calculating and managing technical indicators
class IndicatorService {
  /// Calculate indicator value(s) for a list of candles
  static List<IndicatorResult> calculateIndicatorHistory(
    List<Map<String, dynamic>> candles,
    IndicatorType indicatorType,
    int period,
    Map<String, dynamic>? params,
  ) {
    switch (indicatorType) {
      case IndicatorType.rsi:
        return _calculateRsiHistory(candles, period);
      case IndicatorType.stoch:
        final dPeriod = params?['dPeriod'] as int? ?? 3;
        return _calculateStochasticHistory(candles, period, dPeriod);
      case IndicatorType.macd:
      case IndicatorType.bollinger:
      case IndicatorType.williams:
        // TODO: Implement other indicators
        return [];
    }
  }

  /// Calculate single indicator value incrementally
  static IndicatorResult calculateIndicatorIncremental(
    double currentClose,
    double previousClose,
    IndicatorState? previousState,
    IndicatorType indicatorType,
    int period,
    int timestamp,
    Map<String, dynamic>? params,
  ) {
    switch (indicatorType) {
      case IndicatorType.rsi:
        return RsiService.computeRsiIncremental(
          currentClose,
          previousClose,
          previousState,
          period,
          timestamp,
        );
      case IndicatorType.stoch:
        // Stochastic requires full history, cannot be calculated incrementally
        throw UnsupportedError(
            'Stochastic cannot be calculated incrementally. Use calculateIndicatorHistory instead.');
      case IndicatorType.macd:
      case IndicatorType.bollinger:
      case IndicatorType.williams:
        throw UnimplementedError(
            '${indicatorType.name} calculation not yet implemented');
    }
  }

  /// Calculate RSI history
  static List<IndicatorResult> _calculateRsiHistory(
    List<Map<String, dynamic>> candles,
    int period,
  ) {
    if (candles.length < period + 1) {
      return [];
    }

    final closes = candles.map((c) => c['close'] as double).toList();
    final timestamps = candles.map((c) => c['timestamp'] as int).toList();

    final rsiValues = <double>[];
    double gain = 0, loss = 0;

    // Initial calculation
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

    // Incremental calculation
    for (int i = period + 1; i < closes.length; i++) {
      final change = closes[i] - closes[i - 1];
      final u = change > 0 ? change : 0.0;
      final d = change < 0 ? -change : 0.0;

      au = (au * (period - 1) + u) / period;
      ad = (ad * (period - 1) + d) / period;

      final rs = ad == 0 ? double.infinity : au / ad;
      final rsi = 100 - (100 / (1 + rs));
      rsiValues.add(rsi.clamp(0, 100));
    }

    // Convert to IndicatorResult
    final results = <IndicatorResult>[];
    for (int i = 0; i < rsiValues.length; i++) {
      final idx = period + 1 + i;
      if (idx < candles.length) {
        results.add(IndicatorResult(
          value: rsiValues[i],
          state: IndicatorState({'au': au, 'ad': ad}),
          timestamp: timestamps[idx],
          close: closes[idx],
          indicator: 'rsi',
        ));
      }
    }

    return results;
  }

  /// Calculate Stochastic history
  static List<IndicatorResult> _calculateStochasticHistory(
    List<Map<String, dynamic>> candles,
    int kPeriod,
    int dPeriod,
  ) {
    final stochasticResults = StochasticService.computeStochasticHistory(
      candles,
      kPeriod,
      dPeriod,
    );

    return stochasticResults.map((r) => r.toIndicatorResult()).toList();
  }

  /// Determine indicator zone
  static IndicatorZone getIndicatorZone(
    double value,
    List<double> levels,
    IndicatorType indicatorType,
  ) {
    switch (indicatorType) {
      case IndicatorType.rsi:
        return RsiService.getRsiZone(value, levels);
      case IndicatorType.stoch:
        return StochasticService.getStochasticZone(value, levels);
      case IndicatorType.macd:
      case IndicatorType.bollinger:
      case IndicatorType.williams:
        // Default zone logic for other indicators
        if (levels.isEmpty) return IndicatorZone.between;
        final lowerLevel = levels.first;
        final upperLevel = levels.length > 1 ? levels[1] : 100.0;
        if (value < lowerLevel) return IndicatorZone.below;
        if (value > upperLevel) return IndicatorZone.above;
        return IndicatorZone.between;
    }
  }

  /// Get zone color for UI
  static Color getZoneColor(
    IndicatorZone zone,
    IndicatorType indicatorType,
  ) {
    switch (zone) {
      case IndicatorZone.below:
        return Colors.green;
      case IndicatorZone.between:
        return Colors.orange;
      case IndicatorZone.above:
        return Colors.red;
    }
  }

  /// Get zone icon for UI
  static IconData getZoneIcon(IndicatorZone zone) {
    switch (zone) {
      case IndicatorZone.below:
        return Icons.arrow_downward;
      case IndicatorZone.between:
        return Icons.remove;
      case IndicatorZone.above:
        return Icons.arrow_upward;
    }
  }

  /// Get zone text for UI
  static String getZoneText(
    IndicatorZone zone,
    BuildContext context,
  ) {
    switch (zone) {
      case IndicatorZone.below:
        return 'Below';
      case IndicatorZone.between:
        return 'Between';
      case IndicatorZone.above:
        return 'Above';
    }
  }

  /// Check level crossing (universal)
  static bool checkCrossUp(
    double currentValue,
    double previousValue,
    double level,
  ) {
    return previousValue <= level && currentValue > level;
  }

  static bool checkCrossDown(
    double currentValue,
    double previousValue,
    double level,
  ) {
    return previousValue >= level && currentValue < level;
  }

  /// Check zone entry/exit (universal)
  static bool checkEnterZone(
    double currentValue,
    double previousValue,
    double lowerLevel,
    double upperLevel,
  ) {
    final wasOutside = previousValue < lowerLevel || previousValue > upperLevel;
    final isInside = currentValue >= lowerLevel && currentValue <= upperLevel;
    return wasOutside && isInside;
  }

  static bool checkExitZone(
    double currentValue,
    double previousValue,
    double lowerLevel,
    double upperLevel,
  ) {
    final wasInside =
        previousValue >= lowerLevel && previousValue <= upperLevel;
    final isOutside = currentValue < lowerLevel || currentValue > upperLevel;
    return wasInside && isOutside;
  }

  /// Check alert triggers (universal)
  static List<AlertTrigger> checkAlertTriggers(
    AlertRule rule,
    double currentValue,
    double previousValue,
    int timestamp,
    IndicatorType indicatorType,
  ) {
    final triggers = <AlertTrigger>[];
    final zone = getIndicatorZone(currentValue, rule.levels, indicatorType);
    final indicatorName = indicatorType.name.toUpperCase();

    if (rule.mode == 'cross' && rule.levels.isNotEmpty) {
      for (final level in rule.levels) {
        if (checkCrossUp(currentValue, previousValue, level)) {
          triggers.add(AlertTrigger(
            ruleId: rule.id,
            symbol: rule.symbol,
            indicatorValue: currentValue,
            indicator: indicatorType.toJson(),
            level: level,
            type: AlertType.crossUp,
            zone: zone,
            timestamp: timestamp,
            message: '$indicatorName crossed level $level upward',
          ));
        }

        if (checkCrossDown(currentValue, previousValue, level)) {
          triggers.add(AlertTrigger(
            ruleId: rule.id,
            symbol: rule.symbol,
            indicatorValue: currentValue,
            indicator: indicatorType.toJson(),
            level: level,
            type: AlertType.crossDown,
            zone: zone,
            timestamp: timestamp,
            message: '$indicatorName crossed level $level downward',
          ));
        }
      }
    } else if (rule.mode == 'enter' && rule.levels.length >= 2) {
      if (checkEnterZone(
        currentValue,
        previousValue,
        rule.levels[0],
        rule.levels[1],
      )) {
        triggers.add(AlertTrigger(
          ruleId: rule.id,
          symbol: rule.symbol,
          indicatorValue: currentValue,
          indicator: indicatorType.toJson(),
          level: rule.levels[1],
          type: AlertType.enterZone,
          zone: zone,
          timestamp: timestamp,
          message:
              '$indicatorName entered zone ${rule.levels[0]}-${rule.levels[1]}',
        ));
      }
    } else if (rule.mode == 'exit' && rule.levels.length >= 2) {
      if (checkExitZone(
        currentValue,
        previousValue,
        rule.levels[0],
        rule.levels[1],
      )) {
        triggers.add(AlertTrigger(
          ruleId: rule.id,
          symbol: rule.symbol,
          indicatorValue: currentValue,
          indicator: indicatorType.toJson(),
          level: rule.levels[1],
          type: AlertType.exitZone,
          zone: zone,
          timestamp: timestamp,
          message:
              '$indicatorName exited zone ${rule.levels[0]}-${rule.levels[1]}',
        ));
      }
    }

    return triggers;
  }

  /// Generate sparkline for widget (universal)
  static List<double> generateSparkline(
    List<double> values,
    int maxPoints,
  ) {
    if (values.length <= maxPoints) {
      return values;
    }
    return values.skip(values.length - maxPoints).toList();
  }

  /// Normalize value for display (universal)
  static double normalizeValue(double value) {
    return (value * 10).round() / 10; // Round to 1 decimal place
  }
}

/// Extension to convert RsiResult to IndicatorResult
extension RsiResultExtension on RsiResult {
  IndicatorResult toIndicatorResult() {
    return IndicatorResult(
      value: rsi,
      state: state.toIndicatorState(),
      timestamp: timestamp,
      close: close,
      indicator: 'rsi',
    );
  }
}
