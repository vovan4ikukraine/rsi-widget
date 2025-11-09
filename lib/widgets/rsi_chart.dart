import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../models.dart';
import '../localization/app_localizations.dart';

/// Widget for displaying RSI chart
class RsiChart extends StatelessWidget {
  final List<double> rsiValues;
  final List<int> timestamps; // Timestamps for each RSI point
  final List<double> levels;
  final String symbol;
  final String timeframe;
  final bool showGrid;
  final bool showLabels;
  final Color? lineColor;
  final double lineWidth;
  final bool isInteractive;
  final Function(double)? onTap;

  const RsiChart({
    super.key,
    required this.rsiValues,
    required this.timestamps,
    this.levels = const [30, 70],
    required this.symbol,
    required this.timeframe,
    this.showGrid = true,
    this.showLabels = true,
    this.lineColor,
    this.lineWidth = 2.0,
    this.isInteractive = true,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (rsiValues.isEmpty) {
      return _buildEmptyChart(context);
    }

    return Container(
      height: isInteractive ? 200 : 50, // Fixed height 50 for compact mode
      padding: isInteractive
          ? const EdgeInsets.only(left: 4, right: 4, top: 8, bottom: 8)
          : const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: LineChart(
        LineChartData(
          minY: 0,
          maxY: 100,
          gridData: showGrid ? _buildGridData() : const FlGridData(show: false),
          titlesData:
              showLabels ? _buildTitlesData() : const FlTitlesData(show: false),
          borderData: FlBorderData(show: true),
          lineBarsData: [_buildLineBarData()],
          extraLinesData: _buildExtraLinesData(),
          lineTouchData: isInteractive
              ? _buildLineTouchData()
              : _buildCompactLineTouchData(), // Compact mode with tooltip
        ),
      ),
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

  FlGridData _buildGridData() {
    return FlGridData(
      show: true,
      drawVerticalLine: false,
      horizontalInterval: 20,
      getDrawingHorizontalLine: (value) {
        return FlLine(
          color: Colors.grey[300]!,
          strokeWidth: 0.5,
        );
      },
    );
  }

  FlTitlesData _buildTitlesData() {
    return FlTitlesData(
      show: true,
      rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
      topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
      bottomTitles: AxisTitles(
        sideTitles: SideTitles(
          showTitles: isInteractive, // Show dates only in interactive mode
          reservedSize:
              isInteractive ? 40 : 0, // In compact mode don't reserve space
          interval: _calculateTimeInterval(),
          getTitlesWidget: (value, meta) {
            final label = _formatTimeLabel(value);
            if (label.isEmpty) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                label,
                style: const TextStyle(fontSize: 10),
                textAlign: TextAlign.center,
              ),
            );
          },
        ),
      ),
      leftTitles: AxisTitles(
        sideTitles: SideTitles(
          showTitles: showLabels, // Show labels only if showLabels = true
          reservedSize: isInteractive
              ? 30
              : 25, // Reduced from 40 to 30 for interactive mode
          interval:
              isInteractive ? 20 : 25, // For compact mode: 0, 25, 50, 75, 100
          getTitlesWidget: (value, meta) {
            // In compact mode show only main values
            if (!isInteractive &&
                value != 0 &&
                value != 25 &&
                value != 50 &&
                value != 75 &&
                value != 100) {
              return const SizedBox.shrink();
            }
            return Padding(
              padding: const EdgeInsets.only(right: 2),
              child: Text(
                value.toInt().toString(),
                style: TextStyle(
                  fontSize:
                      isInteractive ? 10 : 8, // Smaller font for compact mode
                ),
                textAlign: TextAlign.right,
              ),
            );
          },
        ),
      ),
    );
  }

  LineChartBarData _buildLineBarData() {
    final spots = rsiValues.asMap().entries.map((entry) {
      return FlSpot(entry.key.toDouble(), entry.value);
    }).toList();

    return LineChartBarData(
      spots: spots,
      isCurved: false,
      color: lineColor ?? _getRsiColor(rsiValues.last),
      barWidth: lineWidth,
      isStrokeCapRound: true,
      dotData: const FlDotData(show: false),
      belowBarData: BarAreaData(show: false),
    );
  }

  ExtraLinesData _buildExtraLinesData() {
    final horizontalLines = <HorizontalLine>[];

    // Add RSI levels
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

    // Add zones
    horizontalLines.addAll(_buildZoneLines());

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
        getTooltipItems: (touchedSpots) {
          return touchedSpots.map((spot) {
            return LineTooltipItem(
              spot.y.toStringAsFixed(1),
              const TextStyle(color: Colors.white, fontSize: 11),
            );
          }).toList();
        },
        tooltipPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      ),
      getTouchLineStart: (data, index) => 0,
      getTouchLineEnd: (data, index) => 100,
      touchSpotThreshold: 10,
      getTouchedSpotIndicator: (barData, spotIndexes) {
        return spotIndexes.map((index) {
          return TouchedSpotIndicatorData(
            const FlLine(
                color: Colors.blue, strokeWidth: 1), // Reduced from 2 to 1
            FlDotData(
              getDotPainter: (spot, percent, barData, index) {
                return FlDotCirclePainter(
                  radius: 3, // Reduced from 4 to 3
                  color: Colors.blue,
                  strokeWidth: 1, // Reduced from 2 to 1
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
        getTooltipItems: (touchedSpots) {
          return touchedSpots.map((spot) {
            final index = spot.x.toInt();
            String dateTimeStr = '';

            // Get date and time for this point
            if (index >= 0 && index < timestamps.length) {
              final timestamp = timestamps[index];
              final date = DateTime.fromMillisecondsSinceEpoch(timestamp);

              // Format date and time depending on timeframe
              switch (timeframe) {
                case '1m':
                case '5m':
                case '15m':
                case '30m':
                  dateTimeStr =
                      '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
                  break;
                case '1h':
                case '4h':
                  dateTimeStr =
                      '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year} ${date.hour.toString().padLeft(2, '0')}:00';
                  break;
                case '1d':
                  dateTimeStr =
                      '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';
                  break;
                default:
                  dateTimeStr =
                      '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
              }
            }

            return LineTooltipItem(
              'RSI: ${spot.y.toStringAsFixed(1)}\n$dateTimeStr',
              const TextStyle(color: Colors.white, fontSize: 12),
            );
          }).toList();
        },
      ),
      getTouchedSpotIndicator: (barData, spotIndexes) {
        return spotIndexes.map((index) {
          return TouchedSpotIndicatorData(
            const FlLine(
                color: Colors.blue, strokeWidth: 1.5), // Reduced from 2 to 1.5
            FlDotData(
              getDotPainter: (spot, percent, barData, index) {
                return FlDotCirclePainter(
                  radius: 3.5, // Reduced from 4 to 3.5
                  color: Colors.blue,
                  strokeWidth: 1.5, // Reduced from 2 to 1.5
                  strokeColor: Colors.white,
                );
              },
            ),
          );
        }).toList();
      },
    );
  }

  Color _getRsiColor(double rsi) {
    if (rsi < 30) return Colors.red;
    if (rsi > 70) return Colors.green;
    return Colors.blue;
  }

  Color _getLevelColor(double level) {
    if (level <= 30) return Colors.red;
    if (level >= 70) return Colors.green;
    return Colors.orange;
  }

  double _calculateTimeInterval() {
    final length = rsiValues.length;
    // Calculate interval depending on number of points
    // For large timeframes show fewer labels
    if (length <= 10) return 1;
    if (length <= 20) return 2;
    if (length <= 50) return length / 5;
    if (length <= 100) return length / 4;
    if (length <= 200) return length / 3;
    return length / 2; // For very large charts show only 2 labels
  }

  String _formatTimeLabel(double value) {
    final index = value.toInt();
    if (index < 0 || index >= rsiValues.length || index >= timestamps.length) {
      return '';
    }

    // Use real timestamps for date formatting
    final timestamp = timestamps[index];
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);

    // Format depending on timeframe
    switch (timeframe) {
      case '1m':
      case '5m':
      case '15m':
      case '30m':
        // For minute timeframes show time
        return '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
      case '1h':
      case '4h':
        // For hourly timeframes show date and hour
        return '${date.day}/${date.month} ${date.hour.toString().padLeft(2, '0')}';
      case '1d':
        // For daily timeframes show only date
        return '${date.day}/${date.month}';
      default:
        // By default show date and time
        return '${date.day}/${date.month} ${date.hour.toString().padLeft(2, '0')}';
    }
  }
}

/// Mini RSI chart for widgets
class RsiMiniChart extends StatelessWidget {
  final List<double> rsiValues;
  final List<double> levels;
  final double currentRsi;
  final String symbol;
  final Color? backgroundColor;
  final Color? lineColor;

  const RsiMiniChart({
    super.key,
    required this.rsiValues,
    this.levels = const [30, 70],
    required this.currentRsi,
    required this.symbol,
    this.backgroundColor,
    this.lineColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 80,
      height: 40,
      decoration: BoxDecoration(
        color: backgroundColor ?? Colors.grey[100],
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.grey[300]!),
      ),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: LineChart(
          LineChartData(
            minY: 0,
            maxY: 100,
            gridData: const FlGridData(show: false),
            titlesData: const FlTitlesData(show: false),
            borderData: FlBorderData(show: false),
            lineBarsData: [
              LineChartBarData(
                spots: rsiValues.asMap().entries.map((e) {
                  return FlSpot(e.key.toDouble(), e.value);
                }).toList(),
                isCurved: false,
                color: lineColor ?? _getRsiColor(currentRsi),
                barWidth: 1.5,
                isStrokeCapRound: true,
                dotData: const FlDotData(show: false),
                belowBarData: BarAreaData(show: false),
              ),
            ],
            extraLinesData: ExtraLinesData(
              horizontalLines: levels.map((level) {
                return HorizontalLine(
                  y: level,
                  color: Colors.grey[400]!,
                  strokeWidth: 0.5,
                );
              }).toList(),
            ),
          ),
        ),
      ),
    );
  }

  Color _getRsiColor(double rsi) {
    if (rsi < 30) return Colors.red;
    if (rsi > 70) return Colors.green;
    return Colors.blue;
  }
}

/// RSI zone indicator
class RsiZoneIndicator extends StatelessWidget {
  final double rsi;
  final List<double> levels;
  final String symbol;

  const RsiZoneIndicator({
    super.key,
    required this.rsi,
    this.levels = const [30, 70],
    required this.symbol,
  });

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final zone = _getRsiZone(rsi, levels);
    final color = _getZoneColor(zone);
    final icon = _getZoneIcon(zone);
    final text = _getZoneText(loc, zone);

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

  RsiZone _getRsiZone(double rsi, List<double> levels) {
    if (levels.isEmpty) return RsiZone.between;

    final lowerLevel = levels.first;
    final upperLevel = levels.length > 1 ? levels[1] : 100.0;

    if (rsi < lowerLevel) {
      return RsiZone.below;
    } else if (rsi > upperLevel) {
      return RsiZone.above;
    } else {
      return RsiZone.between;
    }
  }

  Color _getZoneColor(RsiZone zone) {
    switch (zone) {
      case RsiZone.below:
        return Colors.red;
      case RsiZone.between:
        return Colors.blue;
      case RsiZone.above:
        return Colors.green;
    }
  }

  IconData _getZoneIcon(RsiZone zone) {
    switch (zone) {
      case RsiZone.below:
        return Icons.trending_down;
      case RsiZone.between:
        return Icons.trending_flat;
      case RsiZone.above:
        return Icons.trending_up;
    }
  }

  String _getZoneText(AppLocalizations loc, RsiZone zone) {
    switch (zone) {
      case RsiZone.below:
        return loc.t('chart_zone_oversold');
      case RsiZone.between:
        return loc.t('chart_zone_neutral');
      case RsiZone.above:
        return loc.t('chart_zone_overbought');
    }
  }
}
