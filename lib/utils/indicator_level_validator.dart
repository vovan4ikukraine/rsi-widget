import '../models/indicator_type.dart';
import '../constants/app_constants.dart';

/// Validator for indicator levels (RSI, Stochastic, Williams %R)
class IndicatorLevelValidator {
  /// Validate a single level
  /// Returns null if valid, error message (or ' ' for visual feedback) if invalid
  static String? validateLevel(
    String? value,
    IndicatorType indicatorType,
    bool isEnabled, {
    double? otherLevel,
    bool isLower = true,
  }) {
    if (!isEnabled) return null;
    if (value == null || value.isEmpty) {
      return ' '; // Empty string to show red border only
    }

    final level = int.tryParse(value)?.toDouble();
    if (level == null) {
      return ' '; // Empty string to show red border only
    }

    final isWilliams = indicatorType == IndicatorType.williams;
    final minRange = isWilliams
        ? AppConstants.minWilliamsLevel
        : AppConstants.minIndicatorLevel;
    final maxRange = isWilliams
        ? AppConstants.maxWilliamsLevel
        : AppConstants.maxIndicatorLevel;

    if (level < minRange || level > maxRange) {
      return ' '; // Empty string to show red border only
    }

    // Check relation to other level if both enabled
    if (otherLevel != null) {
      if (isLower && level >= otherLevel) {
        return ' '; // Empty string to show red border only
      }
      if (!isLower && level <= otherLevel) {
        return ' '; // Empty string to show red border only
      }
    }

    return null;
  }

  /// Validate that at least one level is enabled
  static bool validateAtLeastOneLevel({
    required bool lowerEnabled,
    required bool upperEnabled,
  }) {
    return lowerEnabled || upperEnabled;
  }

  /// Validate relationship between levels when both are enabled
  static bool validateLevelsRelationship({
    required double lowerLevel,
    required double upperLevel,
    required bool lowerEnabled,
    required bool upperEnabled,
  }) {
    if (!lowerEnabled || !upperEnabled) return true;
    return lowerLevel < upperLevel;
  }
}
