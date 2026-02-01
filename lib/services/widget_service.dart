import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../di/app_container.dart';
import '../models/indicator_type.dart';
import '../repositories/i_watchlist_repository.dart';
import '../utils/preferences_storage.dart';
import 'yahoo_proto.dart';
import 'indicator_service.dart';

/// Service for updating Android widget with watchlist data
class WidgetService {
  static const MethodChannel _channel =
      MethodChannel('com.indicharts.app/widget');
  final YahooProtoSource yahooService;

  WidgetService({required this.yahooService});

  /// Updates widget with current watchlist data
  Future<void> updateWidget({
    String? timeframe,
    int? rsiPeriod,
    bool sortDescending = false, // Default: ascending (smaller to larger)
    IndicatorType? indicator,
    Map<String, dynamic>? indicatorParams,
  }) async {
    try {
      // Load saved settings from widget (if timeframe was changed in widget)
      final prefs = await PreferencesStorage.instance;
      final savedTimeframe = prefs.getString('rsi_widget_timeframe');
      final savedPeriod = prefs.getInt('rsi_widget_period');
      // Use 'widget_indicator' to match Android native code (MainActivity.kt line 42)
      final savedIndicator = prefs.getString('widget_indicator');
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

      // CRITICAL: Save widget_indicator FIRST and synchronously before calculating data
      // This ensures WidgetDataService.refreshWidgetData reads correct indicator if it runs concurrently
      // Use 'widget_indicator' to match Android native code (MainActivity.kt line 42)
      await prefs.setString('widget_indicator', finalIndicator.toJson());
      await prefs.setString('rsi_widget_timeframe', finalTimeframe);
      await prefs.setInt('rsi_widget_period', finalPeriod);
      await prefs.setBool('rsi_widget_sort_descending', finalSortDescending);
      
      // DEBUG: Log indicator being saved
      debugPrint('WidgetService: Saving widget_indicator=${finalIndicator.toJson()}, period=$finalPeriod, params=$finalIndicatorParams');

      // Load watchlist
      final repo = sl<IWatchlistRepository>();
      final watchlistItems = await repo.getAll();

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

      // Load RSI data for each symbol (parallel batches of 8)
      final widgetData = <Map<String, dynamic>>[];
      const batchSize = 8;

      for (int i = 0; i < watchlistItems.length; i += batchSize) {
        final batch = watchlistItems.skip(i).take(batchSize).toList();
        final batchResults = await Future.wait(
          batch.map((item) async {
            try {
              final candles = await yahooService.fetchCandles(
                item.symbol,
                finalTimeframe,
                limit: _candlesLimitForTimeframe(finalTimeframe, finalPeriod),
              );
              if (candles.isEmpty) return null;
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
              final indicatorResults = IndicatorService.calculateIndicatorHistory(
                candlesList,
                finalIndicator,
                finalPeriod,
                finalIndicatorParams,
              );
              if (indicatorResults.isEmpty) return null;
              final currentValue = indicatorResults.last.value;
              final currentPrice = candles.last.close;
              final previousPrice = candles.length > 1
                  ? candles[candles.length - 2].close
                  : currentPrice;
              final change = currentPrice - previousPrice;
              final indicatorValues = indicatorResults.map((r) => r.value).toList();
              final chartValues = indicatorValues.length > 20
                  ? indicatorValues.sublist(indicatorValues.length - 20)
                  : indicatorValues;
              return <String, dynamic>{
                'symbol': item.symbol,
                'indicatorValue': currentValue,
                'rsi': currentValue,
                'indicator': finalIndicator.toJson(),
                'price': currentPrice,
                'change': change,
                'rsiValues': chartValues,
                'indicatorValues': chartValues,
              };
            } catch (e) {
              debugPrint('Error loading data for ${item.symbol}: $e');
              return null;
            }
          }),
          eagerError: false,
        );
        for (final data in batchResults) {
          if (data != null) widgetData.add(data);
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
          debugPrint('Error saving to iOS App Group: $e');
          // Fallback: save to standard UserDefaults (will need App Group configured)
        }
      }

      debugPrint('Widget updated with ${widgetData.length} items');
    } catch (e) {
      debugPrint('Error updating widget: $e');
    }
  }

  /// Calculate optimal candle limit based on timeframe and period
  /// Ensures we have enough candles for indicator calculation + buffer for charts
  int _candlesLimitForTimeframe(String timeframe, [int? period]) {
    // Minimum candles required for indicators: period + buffer (20 for smoothing and charts)
    final periodBuffer = period != null ? period + 20 : 34; // Default: 14 + 20 = 34
    
    // Base minimums per timeframe (reduced for 4h/1d as they're excessive)
    int baseMinimum;
    switch (timeframe) {
      case '4h':
        baseMinimum = 100; // Same as other timeframes - period-based calculation handles large periods
        break;
      case '1d':
        baseMinimum = 100; // Same as other timeframes - period-based calculation handles large periods
        break;
      default:
        // 1m, 5m, 15m, 1h: base minimum for small periods (100 for charts and stability)
        baseMinimum = 100;
        break;
    }
    
    // Return max of period requirement and base minimum
    return periodBuffer > baseMinimum ? periodBuffer : baseMinimum;
  }
}
