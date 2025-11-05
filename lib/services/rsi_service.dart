import '../models.dart';

/// Сервис для расчета RSI по алгоритму Wilder
class RsiService {
  /// Расчет RSI для списка цен закрытия
  static double? computeRsi(List<double> closes, int period) {
    if (closes.length < period + 1) return null;

    // Расчет первых средних значений
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

    // Инкрементальный расчет для остальных точек
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

  /// Инкрементальный расчет RSI с состоянием
  static RsiResult computeRsiIncremental(
    double currentClose,
    double previousClose,
    RsiState? previousState,
    int period,
    int timestamp,
  ) {
    final change = currentClose - previousClose;
    final u = change > 0 ? change : 0.0;
    final d = change < 0 ? -change : 0.0;

    double au, ad;
    if (previousState == null) {
      // Первое значение - используем простую среднюю
      au = u;
      ad = d;
    } else {
      // Инкрементальное обновление по Wilder
      au = (previousState.au * (period - 1) + u) / period;
      ad = (previousState.ad * (period - 1) + d) / period;
    }

    final state = RsiState(au, ad);
    double rsi;

    if (ad == 0) {
      rsi = 100.0;
    } else {
      final rs = au / ad;
      rsi = 100 - (100 / (1 + rs));
    }

    return RsiResult(
      rsi: rsi.clamp(0, 100),
      state: state,
      timestamp: timestamp,
      close: currentClose,
    );
  }

  /// Определение зоны RSI
  static RsiZone getRsiZone(double rsi, List<double> levels) {
    if (levels.isEmpty) return RsiZone.between;

    final lowerLevel = levels.first;
    final upperLevel = levels.length > 1 ? levels[1] : 100.0;

    if (rsi < lowerLevel) {
      return RsiZone.below;
    } else if (rsi > upperLevel) {
      return RsiZone.above;
    } else {
      return RsiZone.between;
    }
  }

  /// Проверка пересечения уровня с гистерезисом
  static bool checkCrossUp(
    double currentRsi,
    double previousRsi,
    double level,
    double hysteresis,
  ) {
    return previousRsi <= (level - hysteresis) &&
        currentRsi > (level + hysteresis);
  }

  /// Проверка пересечения уровня вниз с гистерезисом
  static bool checkCrossDown(
    double currentRsi,
    double previousRsi,
    double level,
    double hysteresis,
  ) {
    return previousRsi >= (level + hysteresis) &&
        currentRsi < (level - hysteresis);
  }

  /// Проверка входа в зону
  static bool checkEnterZone(
    double currentRsi,
    double previousRsi,
    double lowerLevel,
    double upperLevel,
    double hysteresis,
  ) {
    final wasOutside = previousRsi < (lowerLevel - hysteresis) ||
        previousRsi > (upperLevel + hysteresis);
    final isInside = currentRsi >= (lowerLevel + hysteresis) &&
        currentRsi <= (upperLevel - hysteresis);

    return wasOutside && isInside;
  }

  /// Проверка выхода из зоны
  static bool checkExitZone(
    double currentRsi,
    double previousRsi,
    double lowerLevel,
    double upperLevel,
    double hysteresis,
  ) {
    final wasInside = previousRsi >= (lowerLevel - hysteresis) &&
        previousRsi <= (upperLevel + hysteresis);
    final isOutside = currentRsi < (lowerLevel + hysteresis) ||
        currentRsi > (upperLevel - hysteresis);

    return wasInside && isOutside;
  }

  /// Проверка срабатывания алерта
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
        if (checkCrossUp(currentRsi, previousRsi, level, rule.hysteresis)) {
          triggers.add(AlertTrigger(
            ruleId: rule.id,
            symbol: rule.symbol,
            rsi: currentRsi,
            level: level,
            type: AlertType.crossUp,
            zone: zone,
            timestamp: timestamp,
            message: 'RSI пересек уровень $level вверх',
          ));
        }

        if (checkCrossDown(currentRsi, previousRsi, level, rule.hysteresis)) {
          triggers.add(AlertTrigger(
            ruleId: rule.id,
            symbol: rule.symbol,
            rsi: currentRsi,
            level: level,
            type: AlertType.crossDown,
            zone: zone,
            timestamp: timestamp,
            message: 'RSI пересек уровень $level вниз',
          ));
        }
      }
    } else if (rule.mode == 'enter' && rule.levels.length >= 2) {
      if (checkEnterZone(
        currentRsi,
        previousRsi,
        rule.levels[0],
        rule.levels[1],
        rule.hysteresis,
      )) {
        triggers.add(AlertTrigger(
          ruleId: rule.id,
          symbol: rule.symbol,
          rsi: currentRsi,
          level: rule.levels[1],
          type: AlertType.enterZone,
          zone: zone,
          timestamp: timestamp,
          message: 'RSI вошел в зону ${rule.levels[0]}-${rule.levels[1]}',
        ));
      }
    } else if (rule.mode == 'exit' && rule.levels.length >= 2) {
      if (checkExitZone(
        currentRsi,
        previousRsi,
        rule.levels[0],
        rule.levels[1],
        rule.hysteresis,
      )) {
        triggers.add(AlertTrigger(
          ruleId: rule.id,
          symbol: rule.symbol,
          rsi: currentRsi,
          level: rule.levels[1],
          type: AlertType.exitZone,
          zone: zone,
          timestamp: timestamp,
          message: 'RSI вышел из зоны ${rule.levels[0]}-${rule.levels[1]}',
        ));
      }
    }

    return triggers;
  }

  /// Генерация спарклайна для виджета
  static List<double> generateSparkline(List<double> rsiValues, int maxPoints) {
    if (rsiValues.length <= maxPoints) {
      return rsiValues;
    }

    // Берем последние maxPoints значений
    return rsiValues.skip(rsiValues.length - maxPoints).toList();
  }

  /// Нормализация RSI для отображения
  static double normalizeRsi(double rsi) {
    return (rsi * 10).round() / 10; // Округление до 1 знака после запятой
  }
}
