import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:isar/isar.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models.dart';
import 'yahoo_proto.dart';

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
  }) async {
    try {
      // Load saved settings from widget (if timeframe was changed in widget)
      final prefs = await SharedPreferences.getInstance();
      final savedTimeframe = prefs.getString('rsi_widget_timeframe');
      final savedPeriod = prefs.getInt('rsi_widget_period');

      // Use passed parameters or saved in widget
      final finalTimeframe = timeframe ?? savedTimeframe ?? '15m';
      final finalPeriod = rsiPeriod ?? savedPeriod ?? 14;

      // Save used values
      await prefs.setString('rsi_widget_timeframe', finalTimeframe);
      await prefs.setInt('rsi_widget_period', finalPeriod);

      // Load watchlist
      final watchlistItems = await isar.watchlistItems.where().findAll();

      // Save symbol list in SharedPreferences for widget
      final watchlistSymbols =
          watchlistItems.map((item) => item.symbol).toList();
      await prefs.setString('watchlist_symbols', jsonEncode(watchlistSymbols));

      if (watchlistItems.isEmpty) {
        // No items - send empty list
        await _channel.invokeMethod('updateWidget', {
          'watchlistData': '[]',
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
            limit: 100,
          );

          if (candles.isEmpty) continue;

          // Calculate RSI
          final closes = candles.map((c) => c.close).toList();
          final rsiValues = _calculateRSI(closes, finalPeriod);

          if (rsiValues.isEmpty) continue;

          final currentRsi = rsiValues.last;
          final currentPrice = closes.last;
          final previousPrice =
              closes.length > 1 ? closes[closes.length - 2] : currentPrice;
          final change = currentPrice - previousPrice;

          // Take last 20 values for chart
          final chartValues = rsiValues.length > 20
              ? rsiValues.sublist(rsiValues.length - 20)
              : rsiValues;

          widgetData.add({
            'symbol': item.symbol,
            'rsi': currentRsi,
            'price': currentPrice,
            'change': change,
            'rsiValues': chartValues,
          });
        } catch (e) {
          // Skip symbols with errors
          print('Error loading data for ${item.symbol}: $e');
          continue;
        }
      }

      // Convert to JSON
      final jsonData = jsonEncode(widgetData);

      // Update widget via MethodChannel
      await _channel.invokeMethod('updateWidget', {
        'watchlistData': jsonData,
        'timeframe': finalTimeframe,
        'rsiPeriod': finalPeriod,
      });

      print('Widget updated with ${widgetData.length} items');
    } catch (e) {
      print('Error updating widget: $e');
    }
  }

  /// Calculates RSI using Wilder's algorithm
  List<double> _calculateRSI(List<double> closes, int period) {
    if (closes.length < period + 1) {
      return [];
    }

    final rsiValues = <double>[];

    // Calculate initial average values
    double gain = 0, loss = 0;
    for (int i = 1; i <= period; i++) {
      final change = closes[i] - closes[i - 1];
      if (change > 0) {
        gain += change;
      } else {
        loss -= change;
      }
    }

    double au = gain / period; // Average Up
    double ad = loss / period; // Average Down

    // Incremental calculation for remaining points
    for (int i = period + 1; i < closes.length; i++) {
      final change = closes[i] - closes[i - 1];
      final u = change > 0 ? change : 0.0;
      final d = change < 0 ? -change : 0.0;

      // Update using Wilder's formula
      au = (au * (period - 1) + u) / period;
      ad = (ad * (period - 1) + d) / period;

      // Calculate RSI
      if (ad == 0) {
        rsiValues.add(100.0);
      } else {
        final rs = au / ad;
        final rsi = 100 - (100 / (1 + rs));
        rsiValues.add(rsi.clamp(0, 100));
      }
    }

    return rsiValues;
  }
}
