import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/services.dart';
import 'package:isar/isar.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models.dart';
import '../models/indicator_type.dart';
import 'yahoo_proto.dart';
import 'indicator_service.dart';

/// Service for updating Android widget with watchlist data
class WidgetService {
  static const MethodChannel _channel =
      MethodChannel('com.example.rsi_widget/widget');
  final Isar isar;
  final YahooProtoSource yahooService;

  WidgetService({
    required this.isar,
    required this.yahooService,
  });

  /// Updates widget with current watchlist data
  Future<void> updateWidget({
    String? timeframe,
    int? rsiPeriod,
    bool sortDescending = true,
    IndicatorType? indicator,
    Map<String, dynamic>? indicatorParams,
  }) async {
    try {
      // Load saved settings from widget (if timeframe was changed in widget)
      final prefs = await SharedPreferences.getInstance();
      final savedTimeframe = prefs.getString('rsi_widget_timeframe');
      final savedPeriod = prefs.getInt('rsi_widget_period');
      final savedIndicator = prefs.getString('rsi_widget_indicator');
      final savedSortOrder = prefs.getBool('rsi_widget_sort_descending');

      // Use passed parameters or saved in widget
      final finalTimeframe = timeframe ?? savedTimeframe ?? '15m';
      final finalPeriod = rsiPeriod ?? savedPeriod ?? 14;
      final finalIndicator = indicator ??
          (savedIndicator != null
              ? IndicatorType.fromJson(savedIndicator)
              : IndicatorType.rsi);
      final finalSortDescending = savedSortOrder ?? sortDescending;
      final finalIndicatorParams = indicatorParams;

      // Save used values
      await prefs.setString('rsi_widget_timeframe', finalTimeframe);
      await prefs.setInt('rsi_widget_period', finalPeriod);
      await prefs.setString('rsi_widget_indicator', finalIndicator.toJson());
      await prefs.setBool('rsi_widget_sort_descending', finalSortDescending);

      // Load watchlist
      final watchlistItems = await isar.watchlistItems.where().findAll();

      if (watchlistItems.isEmpty) {
        // Clear both watchlist_symbols and watchlist_data to prevent widget from using old data
        await prefs.setString('watchlist_symbols', '[]');
        // Also clear watchlist_data via MethodChannel to ensure native side clears it
        await _channel.invokeMethod('updateWidget', {
          'watchlistData': '[]',
          'watchlistSymbols': <String>[],
          'timeframe': timeframe,
        });
        return;
      }

      // Load RSI data for each symbol
      final widgetData = <Map<String, dynamic>>[];

      for (final item in watchlistItems) {
        try {
          // Load candles
          final candles = await yahooService.fetchCandles(
            item.symbol,
            finalTimeframe,
            limit: _candlesLimitForTimeframe(finalTimeframe),
          );

          if (candles.isEmpty) continue;

          // Convert candles to format expected by IndicatorService
          final candlesList = candles
              .map(
                (c) => {
                  'open': c.open,
                  'high': c.high,
                  'low': c.low,
                  'close': c.close,
                  'timestamp': c.timestamp,
                },
              )
              .toList();

          // Calculate indicator using IndicatorService
          final indicatorResults = IndicatorService.calculateIndicatorHistory(
            candlesList,
            finalIndicator,
            finalPeriod,
            finalIndicatorParams,
          );

          if (indicatorResults.isEmpty) continue;

          final currentValue = indicatorResults.last.value;
          final currentPrice = candles.last.close;
          final previousPrice = candles.length > 1
              ? candles[candles.length - 2].close
              : currentPrice;
          final change = currentPrice - previousPrice;

          // Take last 20 values for chart
          final indicatorValues = indicatorResults.map((r) => r.value).toList();
          final chartValues = indicatorValues.length > 20
              ? indicatorValues.sublist(indicatorValues.length - 20)
              : indicatorValues;

          widgetData.add({
            'symbol': item.symbol,
            'indicatorValue': currentValue,
            'rsi': currentValue, // Keep for backward compatibility
            'indicator': finalIndicator.toJson(),
            'price': currentPrice,
            'change': change,
            'rsiValues': chartValues,
            'indicatorValues': chartValues, // New field for generic indicator
          });
        } catch (e) {
          // Skip symbols with errors
          print('Error loading data for ${item.symbol}: $e');
          continue;
        }
      }

      // Sort data: always sort by indicator value
      // For RSI and STOCH: ascending (low to high)
      // For WPR: descending (high to low, since values are negative)
      final shouldSortDescending = finalIndicator == IndicatorType.williams;
      
      double resolveValue(Map<String, dynamic> item) {
        final value = (item['indicatorValue'] as num?)?.toDouble() ??
            (item['rsi'] as num?)?.toDouble();
        if (value == null) {
          return shouldSortDescending
              ? double.negativeInfinity
              : double.infinity;
        }
        return value;
      }

      widgetData.sort((a, b) {
        final valueA = resolveValue(a);
        final valueB = resolveValue(b);
        return shouldSortDescending
            ? valueB.compareTo(valueA)
            : valueA.compareTo(valueB);
      });
      final sortedSymbols =
          widgetData.map((item) => item['symbol'] as String).toList();
      await prefs.setString('watchlist_symbols', jsonEncode(sortedSymbols));

      final jsonData = jsonEncode(widgetData);

      // Update widget via MethodChannel (Android)
      if (Platform.isAndroid) {
        await _channel.invokeMethod('updateWidget', {
          'watchlistData': jsonData,
          'timeframe': finalTimeframe,
          'rsiPeriod': finalPeriod,
          'indicator': finalIndicator.toJson(),
          'indicatorParams': finalIndicatorParams != null
              ? jsonEncode(finalIndicatorParams)
              : null,
          'watchlistSymbols': sortedSymbols,
        });
      }

      // For iOS, save to App Group UserDefaults
      if (Platform.isIOS) {
        try {
          await _channel.invokeMethod('saveToAppGroup', {
            'watchlistData': jsonData,
            'timeframe': finalTimeframe,
            'rsiPeriod': finalPeriod,
            'indicator': finalIndicator.toJson(),
            'indicatorParams': finalIndicatorParams != null
                ? jsonEncode(finalIndicatorParams)
                : null,
            'watchlistSymbols': sortedSymbols,
          });

          // Also reload widget timeline
          await _channel.invokeMethod('reloadWidgetTimeline');
        } catch (e) {
          print('Error saving to iOS App Group: $e');
          // Fallback: save to standard UserDefaults (will need App Group configured)
        }
      }

      print('Widget updated with ${widgetData.length} items');
    } catch (e) {
      print('Error updating widget: $e');
    }
  }

  int _candlesLimitForTimeframe(String timeframe) {
    switch (timeframe) {
      case '4h':
        return 500;
      case '1d':
        return 730;
      default:
        return 100;
    }
  }
}
