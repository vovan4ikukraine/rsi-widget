/// Application-wide constants
class AppConstants {
  // Watchlist limits
  static const int maxWatchlistItems = 30;
  
  // Alert limits
  static const int maxCustomAlerts = 20;
  
  // Chart and data limits
  static const int minCandlesForChart = 100;
  static const int periodBuffer = 20;
  
  // Alert defaults
  static const int defaultCooldownSec = 600;
  static const int defaultIndicatorPeriod = 14;
  static const List<double> defaultLevels = [30.0, 70.0];
  
  // Alert prefixes
  static const String watchlistAlertPrefix = 'WATCHLIST:';
  
  // Timeframes
  static const List<String> availableTimeframes = ['1m', '5m', '15m', '1h', '4h', '1d'];
  
  // Indicator ranges
  static const double minIndicatorLevel = 1.0;
  static const double maxIndicatorLevel = 99.0;
  static const double minWilliamsLevel = -99.0;
  static const double maxWilliamsLevel = -1.0;
  
  // Period limits
  static const int minPeriod = 2;
  static const int maxPeriod = 100;
  
  // SnackBar durations
  static const Duration snackBarShortDuration = Duration(seconds: 2);
  static const Duration snackBarMediumDuration = Duration(seconds: 3);
  static const Duration snackBarLongDuration = Duration(seconds: 30);
}
