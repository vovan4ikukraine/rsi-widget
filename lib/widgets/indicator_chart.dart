import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../models.dart';
import '../models/indicator_type.dart';
import '../localization/app_localizations.dart';

/// Universal widget for displaying indicator charts
/// Supports fixed range (0-100) for RSI/STOCH and fixed range (-100 to 0) for Williams %R
class IndicatorChart extends StatelessWidget {
  final List<IndicatorResult> indicatorResults;
  final List<int> timestamps; // Timestamps for each indicator point
  final IndicatorType indicatorType;
  final List<double> levels;
  final String symbol;
  final String timeframe;
  final bool showGrid;
  final bool showLabels;
  final Color? lineColor;
  final double lineWidth;
  final bool isInteractive;

  const IndicatorChart({
    super.key,
    required this.indicatorResults,
    required this.timestamps,
    required this.indicatorType,
    this.levels = const [],
    required this.symbol,
    required this.timeframe,
    this.showGrid = true,
    this.showLabels = true,
    this.lineColor,
    this.lineWidth = 2.0,
    this.isInteractive = true,
  });

  @override
  Widget build(BuildContext context) {
    if (indicatorResults.isEmpty) {
      return _buildEmptyChart(context);
    }

    // Extract values based on indicator type
    final mainValues = indicatorResults.map((r) => r.value).toList();

    // Calculate min/max based on indicator type
    double minY, maxY;
    if (indicatorType == IndicatorType.williams) {
      // Fixed range for Williams %R (-100 to 0)
      minY = -100.0;
      maxY = 0.0;
    } else {
      // Fixed range for RSI/STOCH (0 to 100)
      minY = 0.0;
      maxY = 100.0;
    }

    final chart = Container(
      height: isInteractive ? 200 : 50,
      padding: isInteractive
          ? const EdgeInsets.only(left: 4, right: 4, top: 8, bottom: 8)
          : const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: LineChart(
        LineChartData(
          minY: minY,
          maxY: maxY,
          clipData: const FlClipData.all(),
          gridData: showGrid ? _buildGridData(minY, maxY) : const FlGridData(show: false),
          titlesData:
              showLabels ? _buildTitlesData(minY, maxY) : const FlTitlesData(show: false),
          borderData: FlBorderData(show: true),
          lineBarsData: _buildLineBarsData(mainValues),
          extraLinesData: _buildExtraLinesData(minY, maxY),
          lineTouchData: isInteractive
              ? _buildLineTouchData()
              : _buildCompactLineTouchData(),
        ),
      ),
    );

    return ClipRect(
      child: chart,
    );
  }

  Widget _buildEmptyChart(BuildContext context) {
    final loc = context.loc;
    return Container(
      height: 200,
      padding: const EdgeInsets.all(16),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.show_chart,
              size: 48,
              color: Colors.grey[400],
            ),
            const SizedBox(height: 8),
            Text(
              loc.t('chart_no_data_for', params: {'symbol': symbol}),
              style: TextStyle(
                color: Colors.grey[400],
                fontSize: 16,
              ),
            ),
          ],
        ),
      ),
    );
  }

  FlGridData _buildGridData(double minY, double maxY) {
    final interval = indicatorType == IndicatorType.williams ? 20.0 : 20.0; // 20 units for both
    return FlGridData(
      show: true,
      drawVerticalLine: false,
      horizontalInterval: interval,
      getDrawingHorizontalLine: (value) {
        return FlLine(
          color: Colors.grey[300]!,
          strokeWidth: 0.5,
        );
      },
    );
  }

  FlTitlesData _buildTitlesData(double minY, double maxY) {
    final interval = isInteractive ? 20.0 : 25.0;
    return FlTitlesData(
      show: true,
      rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
      topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
      bottomTitles: const AxisTitles(
        sideTitles: SideTitles(showTitles: false),
      ),
      leftTitles: AxisTitles(
        sideTitles: SideTitles(
          showTitles: showLabels,
          reservedSize: isInteractive ? 30 : 25,
          interval: interval,
          getTitlesWidget: (value, meta) {
            if (!isInteractive) {
              // For compact view, show only key values
              if (indicatorType == IndicatorType.williams) {
                if (value != -100 && value != -80 && value != -50 && value != -20 && value != 0) {
                  return const SizedBox.shrink();
                }
              } else {
                if (value != 0 && value != 25 && value != 50 && value != 75 && value != 100) {
                  return const SizedBox.shrink();
                }
              }
            }
            return Padding(
              padding: const EdgeInsets.only(right: 2),
              child: Text(
                _formatYValue(value),
                style: TextStyle(fontSize: isInteractive ? 10 : 8),
                textAlign: TextAlign.right,
              ),
            );
          },
        ),
      ),
    );
  }

  String _formatYValue(double value) {
    return value.toInt().toString();
  }

  List<LineChartBarData> _buildLineBarsData(List<double> mainValues) {
    final mainSpots = mainValues.asMap().entries.map((entry) {
      return FlSpot(entry.key.toDouble(), entry.value);
    }).toList();

    return [
      LineChartBarData(
        spots: mainSpots,
        isCurved: false,
        color: lineColor ?? _getMainLineColor(mainValues.last),
        barWidth: lineWidth,
        isStrokeCapRound: true,
        dotData: const FlDotData(show: false),
        belowBarData: BarAreaData(show: false),
      ),
    ];
  }

  ExtraLinesData _buildExtraLinesData(double minY, double maxY) {
    final horizontalLines = <HorizontalLine>[];

    // Add indicator levels
    for (final level in levels) {
      horizontalLines.add(
        HorizontalLine(
          y: level,
          color: _getLevelColor(level),
          strokeWidth: 1.5,
          dashArray: [5, 5],
        ),
      );
    }

    // Add zones for indicators with two levels
    if (levels.length >= 2) {
      horizontalLines.addAll(_buildZoneLines());
    }

    return ExtraLinesData(horizontalLines: horizontalLines);
  }

  List<HorizontalLine> _buildZoneLines() {
    final lines = <HorizontalLine>[];

    if (levels.length >= 2) {
      final lowerLevel = levels[0];
      final upperLevel = levels[1];

      // Oversold zone (below lower level)
      lines.add(
        HorizontalLine(
          y: lowerLevel,
          color: Colors.red.withValues(alpha: 0.3),
          strokeWidth: 0,
        ),
      );

      // Overbought zone (above upper level)
      lines.add(
        HorizontalLine(
          y: upperLevel,
          color: Colors.green.withValues(alpha: 0.3),
          strokeWidth: 0,
        ),
      );
    }

    return lines;
  }

  LineTouchData _buildCompactLineTouchData() {
    return LineTouchData(
      enabled: true,
      touchTooltipData: LineTouchTooltipData(
        getTooltipColor: (spot) => Colors.blue.withValues(alpha: 0.8),
        tooltipMargin: 8,
        fitInsideHorizontally: true,
        fitInsideVertically: true,
        getTooltipItems: (touchedSpots) {
          if (touchedSpots.isEmpty) return [];
          
          final firstSpot = touchedSpots.first;
          final index = firstSpot.x.toInt().clamp(0, timestamps.length - 1);
          final timestamp = timestamps[index];
          final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
          final formatted = _formatTooltipDate(date);

          final currentValue = _formatTooltipValue(firstSpot.y);
          final tooltipText = '${indicatorType.name}: $currentValue\n$formatted';
          
          return [
            LineTooltipItem(
              tooltipText,
              const TextStyle(color: Colors.white, fontSize: 11),
            ),
          ];
        },
        tooltipPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      ),
      getTouchLineStart: (data, index) => 0,
      getTouchLineEnd: (data, index) => 100,
      touchSpotThreshold: 10,
      getTouchedSpotIndicator: (barData, spotIndexes) {
        return spotIndexes.map((index) {
          return TouchedSpotIndicatorData(
            const FlLine(color: Colors.blue, strokeWidth: 1),
            FlDotData(
              getDotPainter: (spot, percent, barData, index) {
                return FlDotCirclePainter(
                  radius: 3,
                  color: Colors.blue,
                  strokeWidth: 1,
                  strokeColor: Colors.white,
                );
              },
            ),
          );
        }).toList();
      },
    );
  }

  LineTouchData _buildLineTouchData() {
    return LineTouchData(
      enabled: true,
      touchTooltipData: LineTouchTooltipData(
        getTooltipColor: (spot) => Colors.blue.withValues(alpha: 0.8),
        tooltipPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        tooltipMargin: 12,
        fitInsideHorizontally: true,
        fitInsideVertically: true,
        getTooltipItems: (touchedSpots) {
          if (touchedSpots.isEmpty) return [];
          
          final firstSpot = touchedSpots.first;
          final index = firstSpot.x.toInt().clamp(0, timestamps.length - 1);
          final date = DateTime.fromMillisecondsSinceEpoch(timestamps[index]);
          final formatted = _formatTooltipDate(date);

          final currentValue = _formatTooltipValue(firstSpot.y);
          final tooltipText = '${indicatorType.name}: $currentValue\n$formatted';
          
          // Return tooltip for all spots (usually just one), but with same text to avoid duplication
          return touchedSpots.map((spot) {
            return LineTooltipItem(
              tooltipText,
              const TextStyle(color: Colors.white, fontSize: 12),
            );
          }).toList();
        },
      ),
      getTouchedSpotIndicator: (barData, spotIndexes) {
        return spotIndexes.map((index) {
          return TouchedSpotIndicatorData(
            const FlLine(color: Colors.blue, strokeWidth: 1.5),
            FlDotData(
              getDotPainter: (spot, percent, barData, index) {
                return FlDotCirclePainter(
                  radius: 3.5,
                  color: Colors.blue,
                  strokeWidth: 1.5,
                  strokeColor: Colors.white,
                );
              },
            ),
          );
        }).toList();
      },
    );
  }

  String _formatTooltipValue(double value) {
    return value.toStringAsFixed(1);
  }

  String _formatTooltipDate(DateTime date) {
    switch (timeframe) {
      case '1m':
      case '5m':
      case '15m':
      case '30m':
        return '${_two(date.day)}/${_two(date.month)}/${date.year} ${_two(date.hour)}:${_two(date.minute)}';
      case '1h':
      case '4h':
        return '${_two(date.day)}/${_two(date.month)}/${date.year} ${_two(date.hour)}:00';
      case '1d':
        return '${_two(date.day)}/${_two(date.month)}/${date.year}';
      default:
        return '${_two(date.day)}/${_two(date.month)}/${date.year} ${_two(date.hour)}:${_two(date.minute)}';
    }
  }

  String _two(int value) => value.toString().padLeft(2, '0');

  Color _getMainLineColor(double value) {
    switch (indicatorType) {
      case IndicatorType.rsi:
        if (value < 30) return Colors.red;
        if (value > 70) return Colors.green;
        return Colors.blue;
      case IndicatorType.stoch:
        if (value < 20) return Colors.red;
        if (value > 80) return Colors.green;
        return Colors.blue;
      case IndicatorType.williams:
        // For Williams %R, lower values (more negative) = oversold, higher values (less negative) = overbought
        if (value < -80) return Colors.red; // Oversold
        if (value > -20) return Colors.green; // Overbought
        return Colors.blue;
    }
  }

  Color _getLevelColor(double level) {
    if (indicatorType == IndicatorType.williams) {
      // For Williams %R, lower values (more negative) = oversold, higher values (less negative) = overbought
      if (level <= -80) return Colors.red; // Oversold
      if (level >= -20) return Colors.green; // Overbought
      return Colors.orange;
    }
    if (level <= 30) return Colors.red;
    if (level >= 70) return Colors.green;
    return Colors.orange;
  }
}

