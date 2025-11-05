import 'package:isar/isar.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'models.g.dart';
part 'models.freezed.dart';

@collection
class AlertRule {
  Id id = Isar
      .autoIncrement; // Isar автоматически присвоит следующий доступный ID при сохранении

  @Index()
  late String symbol; // e.g. AAPL, EURUSD=X

  late String timeframe; // 1m|5m|15m|1h|4h|1d

  int rsiPeriod = 14;

  List<double> levels = [30, 70];

  String mode = 'cross'; // cross|enter|exit

  double hysteresis = 0.5;

  int cooldownSec = 600;

  bool active = true;

  @Index()
  late int createdAt;

  String? description;

  // Дополнительные настройки
  bool repeatable = true;
  bool soundEnabled = true;
  String? customSound;
}

@collection
class AlertState {
  Id id = Isar
      .autoIncrement; // Isar автоматически присвоит следующий доступный ID при сохранении

  @Index()
  late int ruleId;

  double? lastRsi;

  int? lastBarTs;

  int? lastFireTs;

  String? lastSide; // above|below|between

  // Состояние для гистерезиса
  bool? wasAboveUpper;
  bool? wasBelowLower;

  // Кэш для RSI расчета
  double? lastAu;
  double? lastAd;
}

@collection
class AlertEvent {
  Id id = Isar
      .autoIncrement; // Isar автоматически присвоит следующий доступный ID при сохранении

  @Index()
  late int ruleId;

  late int ts;

  late double rsi;

  double? level;

  String? side;

  int? barTs;

  late String symbol;

  String? message;

  bool isRead = false;
}

@collection
class RsiData {
  Id id = Isar
      .autoIncrement; // Isar автоматически присвоит следующий доступный ID при сохранении

  @Index()
  late String symbol;

  @Index()
  late String timeframe;

  late int timestamp;

  late double rsi;

  late double close;

  // Кэш для инкрементального расчета
  double? au;
  double? ad;
}

@collection
class DeviceInfo {
  Id id = Isar
      .autoIncrement; // Isar автоматически присвоит следующий доступный ID при сохранении

  late String deviceId;

  late String fcmToken;

  late String platform; // ios|android

  late int createdAt;

  bool isActive = true;
}

@collection
class WatchlistItem {
  Id id = Isar.autoIncrement;

  @Index()
  late String symbol;

  @Index()
  late int createdAt;

  WatchlistItem();
}

/// Состояние для инкрементального расчета RSI
class RsiState {
  final double au;
  final double ad;

  RsiState(this.au, this.ad);

  RsiState copyWith({double? au, double? ad}) {
    return RsiState(au ?? this.au, ad ?? this.ad);
  }
}

/// Результат расчета RSI
@freezed
class RsiResult with _$RsiResult {
  const factory RsiResult({
    required double rsi,
    required RsiState state,
    required int timestamp,
    required double close,
  }) = _RsiResult;
}

/// Типы алертов
enum AlertType {
  crossUp,
  crossDown,
  enterZone,
  exitZone,
}

/// Зоны RSI
enum RsiZone {
  below, // ниже нижнего уровня
  between, // между уровнями
  above, // выше верхнего уровня
}

/// Конфигурация алерта
@freezed
class AlertConfig with _$AlertConfig {
  const factory AlertConfig({
    required String symbol,
    required String timeframe,
    required int rsiPeriod,
    required List<double> levels,
    required AlertType type,
    required double hysteresis,
    required int cooldownSec,
    required bool repeatable,
    String? description,
  }) = _AlertConfig;
}

/// Событие срабатывания алерта
@freezed
class AlertTrigger with _$AlertTrigger {
  const factory AlertTrigger({
    required int ruleId,
    required String symbol,
    required double rsi,
    required double level,
    required AlertType type,
    required RsiZone zone,
    required int timestamp,
    String? message,
  }) = _AlertTrigger;
}
