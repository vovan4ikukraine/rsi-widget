import 'package:flutter/material.dart';
import '../models/indicator_type.dart';
import '../state/app_state.dart';

/// Widget for selecting the active indicator
class IndicatorSelector extends StatelessWidget {
  final AppState appState;

  const IndicatorSelector({
    super.key,
    required this.appState,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    
    // Adaptive colors based on theme
    final backgroundColor = isDark ? Colors.blue[900]?.withValues(alpha: 0.3) : Colors.blue[50];
    final textColor = isDark ? Colors.blue[100] : Colors.blue[900];
    final iconColor = isDark ? Colors.blue[200] : Colors.blue[900];
    
    return Container(
      decoration: BoxDecoration(
        color: backgroundColor,
        // Removed bottom border
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.05),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            Icon(Icons.trending_up, size: 22, color: iconColor),
            const SizedBox(width: 10),
            Text(
              'Indicator:',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
                color: textColor,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButton<IndicatorType>(
                value: appState.selectedIndicator,
                isExpanded: true,
                underline: Container(),
                dropdownColor: isDark ? Colors.grey[900] : Colors.white,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 15,
                  color: textColor,
                ),
                icon: Icon(Icons.arrow_drop_down, color: iconColor),
                items: IndicatorType.values.map((indicator) {
                  return DropdownMenuItem<IndicatorType>(
                    value: indicator,
                    child: Text(
                      indicator.name,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: textColor,
                      ),
                    ),
                  );
                }).toList(),
                onChanged: (IndicatorType? newIndicator) {
                  if (newIndicator != null) {
                    appState.setIndicator(newIndicator);
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
