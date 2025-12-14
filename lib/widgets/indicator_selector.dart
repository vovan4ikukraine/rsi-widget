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
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Row(
          children: [
            const Icon(Icons.trending_up, size: 20),
            const SizedBox(width: 8),
            const Text(
              'Indicator:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButton<IndicatorType>(
                value: appState.selectedIndicator,
                isExpanded: true,
                underline: Container(),
                items: IndicatorType.values.map((indicator) {
                  return DropdownMenuItem<IndicatorType>(
                    value: indicator,
                    child: Text(indicator.name),
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
