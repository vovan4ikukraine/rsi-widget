/// Type of price-indicator divergence
enum DivergenceType {
  /// Bullish: price makes lower low, indicator makes higher low
  bullish,
  /// Bearish: price makes higher high, indicator makes lower high
  bearish,
}

/// A detected divergence between price and indicator
class Divergence {
  /// Start index (first extremum)
  final int startIndex;
  /// End index (second extremum)
  final int endIndex;
  final DivergenceType type;

  const Divergence({
    required this.startIndex,
    required this.endIndex,
    required this.type,
  });
}
