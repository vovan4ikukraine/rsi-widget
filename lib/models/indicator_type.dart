enum IndicatorType {
  rsi,
  stoch,
  williams;

  String get name {
    switch (this) {
      case IndicatorType.rsi:
        return 'RSI';
      case IndicatorType.stoch:
        return 'STOCH';
      case IndicatorType.williams:
        return 'WPR';
    }
  }

  String get displayName {
    switch (this) {
      case IndicatorType.rsi:
        return 'RSI (Relative Strength Index)';
      case IndicatorType.stoch:
        return 'Stochastic Oscillator';
      case IndicatorType.williams:
        return 'Williams %R';
    }
  }

  /// Default period for this indicator
  int get defaultPeriod {
    switch (this) {
      case IndicatorType.rsi:
        return 14;
      case IndicatorType.stoch:
        return 6; // %K period (Yahoo Finance default: 6)
      case IndicatorType.williams:
        return 14;
    }
  }

  /// Default levels for this indicator
  List<double> get defaultLevels {
    switch (this) {
      case IndicatorType.rsi:
        return [30, 70];
      case IndicatorType.stoch:
        return [20, 80];
      case IndicatorType.williams:
        return [-80, -20];
    }
  }

  /// Additional parameters needed for this indicator
  Map<String, dynamic> get defaultParams {
    switch (this) {
      case IndicatorType.rsi:
        return {};
      case IndicatorType.stoch:
        return {
          'slowPeriod': 3, // %K smoothing period (Slow Stochastic)
          'dPeriod': 6, // %D period
          'smoothPeriod': 3, // %D smoothing period
        };
      case IndicatorType.williams:
        return {};
    }
  }

  /// Convert to string for storage
  String toJson() => name.toLowerCase();

  /// Convert to server API format (different from toJson for some indicators)
  String toServerJson() {
    switch (this) {
      case IndicatorType.rsi:
        return 'rsi';
      case IndicatorType.stoch:
        return 'stoch';
      case IndicatorType.williams:
        return 'williams'; // Server expects 'williams', not 'wpr'
    }
  }

  /// Create from string
  static IndicatorType fromJson(String value) {
    switch (value.toLowerCase()) {
      case 'rsi':
        return IndicatorType.rsi;
      case 'stoch':
        return IndicatorType.stoch;
      case 'williams':
      case 'wpr':
        return IndicatorType.williams;
      default:
        return IndicatorType.rsi;
    }
  }
}
