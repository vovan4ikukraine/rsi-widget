import 'package:flutter/material.dart';
import '../models/indicator_type.dart';
import '../services/indicator_service.dart';

/// Universal indicator zone indicator widget
class IndicatorZoneIndicator extends StatelessWidget {
  final double value;
  final List<double> levels;
  final String symbol;
  final IndicatorType indicatorType;

  const IndicatorZoneIndicator({
    super.key,
    required this.value,
    this.levels = const [30, 70],
    required this.symbol,
    required this.indicatorType,
  });

  @override
  Widget build(BuildContext context) {
    final zone = IndicatorService.getIndicatorZone(
      value,
      levels,
      indicatorType,
    );
    final color = IndicatorService.getZoneColor(zone, indicatorType);
    final icon = IndicatorService.getZoneIcon(zone);
    final text = IndicatorService.getZoneText(zone, context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}
