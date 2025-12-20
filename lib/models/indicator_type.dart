enum IndicatorType {
  rsi,
  stoch,
  macd,
  bollinger,
  williams;

  String get name {
    switch (this) {
      case IndicatorType.rsi:
        return 'RSI';
      case IndicatorType.stoch:
        return 'STOCH';
      case IndicatorType.macd:
        return 'MACD';
      case IndicatorType.bollinger:
        return 'BOLL';
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
      case IndicatorType.macd:
        return 'MACD (Moving Average Convergence Divergence)';
      case IndicatorType.bollinger:
        return 'Bollinger Bands';
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
      case IndicatorType.macd:
        return 12; // Fast EMA period
      case IndicatorType.bollinger:
        return 20; // SMA period
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
      case IndicatorType.macd:
        return [0]; // Signal line crossover
      case IndicatorType.bollinger:
        return [0]; // Band touch
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
      case IndicatorType.macd:
        return {'slowPeriod': 26, 'signalPeriod': 9};
      case IndicatorType.bollinger:
        return {'stdDev': 2.0};
      case IndicatorType.williams:
        return {};
    }
  }

  /// Convert to string for storage
  String toJson() => name.toLowerCase();

  /// Create from string
  static IndicatorType fromJson(String value) {
    switch (value.toLowerCase()) {
      case 'rsi':
        return IndicatorType.rsi;
      case 'stoch':
        return IndicatorType.stoch;
      case 'macd':
        return IndicatorType.macd;
      case 'bollinger':
      case 'boll':
        return IndicatorType.bollinger;
      case 'williams':
      case 'wpr':
        return IndicatorType.williams;
      default:
        return IndicatorType.rsi;
    }
  }
}
