/// Utility for formatting prices intelligently
/// Handles both regular prices and very small prices (like crypto)
class PriceFormatter {
  /// Format price with appropriate precision based on its magnitude
  /// 
  /// Rules:
  /// - Prices >= 1: 2 decimal places (e.g., 123.45)
  /// - Prices >= 0.01: 4 decimal places (e.g., 0.0675)
  /// - Prices >= 0.0001: 6 decimal places (e.g., 0.000768)
  /// - Prices >= 0.00001: 8 decimal places (e.g., 0.00000768)
  /// - Prices < 0.00001: 10 decimal places, removing trailing zeros (e.g., 0.000000768)
  static String formatPrice(double price) {
    if (price.isNaN || price.isInfinite) {
      return price.toString();
    }

    // Handle zero
    if (price == 0.0) {
      return '0.00';
    }

    // Handle negative prices
    final isNegative = price < 0;
    final absPrice = price.abs();

    String result;

    if (absPrice >= 1.0) {
      // Prices >= 1: 2 decimal places
      result = absPrice.toStringAsFixed(2);
    } else if (absPrice >= 0.01) {
      // Prices >= 0.01: 4 decimal places
      result = absPrice.toStringAsFixed(4);
    } else if (absPrice >= 0.0001) {
      // Prices >= 0.0001: 6 decimal places
      result = absPrice.toStringAsFixed(6);
    } else if (absPrice >= 0.00001) {
      // Prices >= 0.00001: 8 decimal places
      result = absPrice.toStringAsFixed(8);
    } else {
      // Prices < 0.00001: 10 decimal places, then remove trailing zeros
      result = absPrice.toStringAsFixed(10);
      // Remove trailing zeros and trailing decimal point if needed
      result = result.replaceAll(RegExp(r'0+$'), '');
      result = result.replaceAll(RegExp(r'\.$'), '');
    }

    // Add negative sign if needed
    if (isNegative) {
      result = '-$result';
    }

    return result;
  }
}
