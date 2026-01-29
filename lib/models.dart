import 'dart:convert';
import 'package:isar/isar.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'models.g.dart';
part 'models.freezed.dart';

@collection
class AlertRule {
  Id id = Isar
      .autoIncrement; // Isar will automatically assign the next available ID when saving

  int? remoteId;

  @Index()
  late String symbol; // e.g. AAPL, EURUSD=X

  late String timeframe; // 1m|5m|15m|1h|4h|1d

  // Indicator configuration
  late String indicator =
      'rsi'; // Type of indicator: 'rsi', 'stoch', 'macd', etc.
  int period = 14; // Main period (RSI period, %K period for Stochastic, etc.)
  String?
      indicatorParamsJson; // Additional parameters as JSON (e.g., %D period for Stochastic)

  // Helper getter/setter for indicatorParams (converts to/from JSON)
  @ignore
  Map<String, dynamic>? get indicatorParams {
    if (indicatorParamsJson == null || indicatorParamsJson!.isEmpty) {
      return null;
    }
    try {
      return Map<String, dynamic>.from(jsonDecode(indicatorParamsJson!));
    } catch (e) {
      return null;
    }
  }

  set indicatorParams(Map<String, dynamic>? params) {
    if (params == null || params.isEmpty) {
      indicatorParamsJson = null;
      return;
    }
    indicatorParamsJson = jsonEncode(params);
  }

  // Keep rsiPeriod for backward compatibility (deprecated, use period instead)
  @Deprecated('Use period instead')
  int get rsiPeriod => period;
  @Deprecated('Use period instead')
  set rsiPeriod(int value) => period = value;

  List<double> levels = [30, 70];

  String mode = 'cross'; // cross|enter|exit

  int cooldownSec = 600;

  bool active = true;

  @Index()
  late int createdAt;

  String? description;

  /// When true, alert only on candle close (no forming candle). When false, alert on crossing (incl. forming).
  bool alertOnClose = false;

  // Additional settings
  bool repeatable = true;
  bool soundEnabled = true;
  String? customSound;
  
  /// Source of the alert: 'watchlist' for mass alerts, 'custom' for user-created alerts
  /// Used to distinguish notification titles
  String source = 'custom';
}

@collection
class AlertState {
  Id id = Isar
      .autoIncrement; // Isar will automatically assign the next available ID when saving

  @Index()
  late int ruleId;

  // Universal indicator state
  double? lastIndicatorValue; // Last calculated indicator value
  String?
      indicatorStateJson; // State for incremental calculation as JSON (e.g., au/ad for RSI)

  // Helper getter/setter for indicatorState (converts to/from JSON)
  @ignore
  Map<String, dynamic>? get indicatorState {
    if (indicatorStateJson == null || indicatorStateJson!.isEmpty) return null;
    try {
      return Map<String, dynamic>.from(jsonDecode(indicatorStateJson!));
    } catch (e) {
      return null;
    }
  }

  set indicatorState(Map<String, dynamic>? state) {
    if (state == null || state.isEmpty) {
      indicatorStateJson = null;
      return;
    }
    indicatorStateJson = jsonEncode(state);
  }

  int? lastBarTs;

  int? lastFireTs;

  String? lastSide; // above|below|between

  // State for hysteresis
  bool? wasAboveUpper;
  bool? wasBelowLower;

  // Deprecated: Keep for backward compatibility
  @Deprecated('Use lastIndicatorValue instead')
  double? get lastRsi => lastIndicatorValue;
  @Deprecated('Use lastIndicatorValue instead')
  set lastRsi(double? value) => lastIndicatorValue = value;

  @Deprecated('Use indicatorState instead')
  double? get lastAu => indicatorState?['au'] as double?;
  @Deprecated('Use indicatorState instead')
  set lastAu(double? value) {
    final currentState = indicatorState;
    if (currentState == null) {
      indicatorState = {'au': value};
    } else {
      indicatorState = {...currentState, 'au': value};
    }
  }

  @Deprecated('Use indicatorState instead')
  double? get lastAd => indicatorState?['ad'] as double?;
  @Deprecated('Use indicatorState instead')
  set lastAd(double? value) {
    final currentState = indicatorState;
    if (currentState == null) {
      indicatorState = {'ad': value};
    } else {
      indicatorState = {...currentState, 'ad': value};
    }
  }
}

@collection
class AlertEvent {
  Id id = Isar
      .autoIncrement; // Isar will automatically assign the next available ID when saving

  @Index()
  late int ruleId;

  late int ts;

  // Universal indicator value
  late double indicatorValue; // Indicator value that triggered the alert

  String? indicator; // Type of indicator: 'rsi', 'stoch', etc.

  // Deprecated: Keep for backward compatibility
  @Deprecated('Use indicatorValue instead')
  double get rsi => indicatorValue;
  @Deprecated('Use indicatorValue instead')
  set rsi(double value) => indicatorValue = value;

  double? level;

  String? side;

  int? barTs;

  late String symbol;

  String? message;

  bool isRead = false;
}

@collection
class IndicatorData {
  Id id = Isar
      .autoIncrement; // Isar will automatically assign the next available ID when saving

  @Index()
  late String symbol;

  @Index()
  late String timeframe;

  late String indicator; // Type of indicator: 'rsi', 'stoch', etc.

  late int timestamp;

  late double value; // Indicator value

  late double close;

  // Cache for incremental calculation (JSON format for flexibility)
  String?
      stateJson; // State for incremental calculation as JSON (e.g., au/ad for RSI)

  // Helper getter/setter for state (converts to/from JSON)
  @ignore
  Map<String, dynamic>? get state {
    if (stateJson == null || stateJson!.isEmpty) return null;
    try {
      return Map<String, dynamic>.from(jsonDecode(stateJson!));
    } catch (e) {
      return null;
    }
  }

  set state(Map<String, dynamic>? state) {
    if (state == null || state.isEmpty) {
      stateJson = null;
      return;
    }
    stateJson = jsonEncode(state);
  }

  // Deprecated: Keep for backward compatibility
  @Deprecated('Use IndicatorData with indicator field instead')
  double get rsi => value;
  @Deprecated('Use IndicatorData with indicator field instead')
  set rsi(double v) => value = v;

  @Deprecated('Use state instead')
  double? get au => state?['au'] as double?;
  @Deprecated('Use state instead')
  set au(double? v) {
    state ??= {};
    state!['au'] = v;
  }

  @Deprecated('Use state instead')
  double? get ad => state?['ad'] as double?;
  @Deprecated('Use state instead')
  set ad(double? v) {
    state ??= {};
    state!['ad'] = v;
  }
}

// Alias for backward compatibility
@Deprecated('Use IndicatorData instead')
typedef RsiData = IndicatorData;

@collection
class DeviceInfo {
  Id id = Isar
      .autoIncrement; // Isar will automatically assign the next available ID when saving

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

/// State for incremental indicator calculation
/// Universal state that can hold different types of indicator states
class IndicatorState {
  final Map<String, dynamic> data;

  IndicatorState(this.data);

  IndicatorState copyWith(Map<String, dynamic>? updates) {
    if (updates == null) return this;
    return IndicatorState({...data, ...updates});
  }

  // Helper getters for RSI (backward compatibility)
  double? get au => data['au'] as double?;
  double? get ad => data['ad'] as double?;
}

/// Deprecated: Use IndicatorState instead
@Deprecated('Use IndicatorState instead')
class RsiState {
  final double au;
  final double ad;

  RsiState(this.au, this.ad);

  RsiState copyWith({double? au, double? ad}) {
    return RsiState(au ?? this.au, ad ?? this.ad);
  }

  IndicatorState toIndicatorState() {
    return IndicatorState({'au': au, 'ad': ad});
  }
}

/// Indicator calculation result (universal)
@freezed
class IndicatorResult with _$IndicatorResult {
  const IndicatorResult._();

  const factory IndicatorResult({
    required double value, // Indicator value
    required IndicatorState state, // Calculation state
    required int timestamp,
    required double close,
    String? indicator, // Optional: indicator type
  }) = _IndicatorResult;
}

/// Deprecated: Use IndicatorResult instead
@Deprecated('Use IndicatorResult instead')
@freezed
class RsiResult with _$RsiResult {
  const RsiResult._();

  const factory RsiResult({
    required double rsi,
    required RsiState state,
    required int timestamp,
    required double close,
  }) = _RsiResult;

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

/// Alert types
enum AlertType {
  crossUp,
  crossDown,
  enterZone,
  exitZone,
}

/// Indicator zones (universal for all indicators)
enum IndicatorZone {
  below, // below lower level
  between, // between levels
  above, // above upper level
}

/// Deprecated: Use IndicatorZone instead
@Deprecated('Use IndicatorZone instead')
typedef RsiZone = IndicatorZone;

/// Alert configuration
@freezed
class AlertConfig with _$AlertConfig {
  const factory AlertConfig({
    required String symbol,
    required String timeframe,
    required int rsiPeriod,
    required List<double> levels,
    required AlertType type,
    required int cooldownSec,
    required bool repeatable,
    String? description,
  }) = _AlertConfig;
}

/// Alert trigger event (universal)
@freezed
class AlertTrigger with _$AlertTrigger {
  const AlertTrigger._();

  const factory AlertTrigger({
    required int ruleId,
    required String symbol,
    required double indicatorValue, // Indicator value that triggered
    required double level,
    required AlertType type,
    required IndicatorZone zone,
    required int timestamp,
    String? message,
    String? indicator, // Optional: indicator type
  }) = _AlertTrigger;

  // Deprecated: Keep for backward compatibility
  @Deprecated('Use indicatorValue instead')
  double get rsi => indicatorValue;

  @Deprecated('Use IndicatorZone instead')
  IndicatorZone get rsiZone => zone;
}
