import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../data/popular_symbols.dart';
import 'user_service.dart';

import '../config/app_config.dart';

final yahooService = YahooProtoSource(AppConfig.apiBaseUrl);

/// Adapter for getting data from Yahoo Finance through proxy
class YahooProtoSource {
  final String endpoint;
  final http.Client _client = http.Client();

  // Timeout for HTTP requests (10 seconds)
  static const Duration _requestTimeout = Duration(seconds: 10);

  YahooProtoSource(this.endpoint);

  /// Get candles for symbol
  /// Returns a tuple with candles and data source ('cache' or 'yahoo')
  Future<(List<CandleData>, String)> fetchCandlesWithSource(
    String symbol,
    String timeframe, {
    int? since,
    int limit = 1000,
    bool debug = false,
  }) async {
    try {
      // Check client-side cache first for instant response
      // But only use cache if data is fresh (< 60 seconds) for trading app
      final cacheKey = '$symbol:$timeframe';
      final cachedCandles = DataCache.getCandles(cacheKey);
      final cacheTimestamp = DataCache.getCacheTimestamp(cacheKey);

      if (cachedCandles != null &&
          cachedCandles.isNotEmpty &&
          cacheTimestamp != null) {
        // Check if cache is fresh (less than 60 seconds old)
        final cacheAge = DateTime.now().difference(cacheTimestamp);
        if (cacheAge.inSeconds < 60) {
          // Cache is fresh, use it for instant display
          final result = limit < cachedCandles.length
              ? cachedCandles.sublist(cachedCandles.length - limit)
              : cachedCandles;
          debugPrint(
              'YahooProto: Using fresh client cache for $symbol $timeframe (${result.length} candles, age: ${cacheAge.inSeconds}s)');
          return (result, 'client-cache');
        } else {
          // Cache is stale (> 60 seconds), will fetch fresh data below
          debugPrint(
              'YahooProto: Client cache is stale for $symbol $timeframe (age: ${cacheAge.inSeconds}s), fetching fresh data');
        }
      }

      // Get userId for activity tracking (optional - doesn't break if null)
      final userId = UserService.currentUserId;

      final uri = Uri.parse('$endpoint/yf/candles').replace(
        queryParameters: {
          'symbol': symbol,
          'tf': timeframe,
          if (since != null) 'since': since.toString(),
          'limit': limit.toString(),
          if (debug) 'debug': 'true',
          if (userId != null) 'userId': userId, // Track user activity when fetching candles
        },
      );

      final response = await _client.get(
        uri,
        headers: {'accept': 'application/json'},
      ).timeout(_requestTimeout, onTimeout: () {
        throw YahooException('Request timeout');
      });

      if (response.statusCode != 200) {
        final errorBody = response.body;
        throw YahooException(
            'HTTP error ${response.statusCode} for $symbol $timeframe: $errorBody');
      }

      // Get data source from header
      String dataSource = 'unknown';
      final headerSource = response.headers['x-data-source'];
      if (headerSource != null) {
        dataSource = headerSource.toLowerCase();
      }

      final decoded = json.decode(response.body);

      // Check for server error
      if (decoded is Map && decoded.containsKey('error')) {
        final errorMsg = decoded['error'];
        throw YahooException(
            'Server returned error for $symbol $timeframe: $errorMsg');
      }

      // Handle debug mode response
      List<dynamic> data;
      if (debug &&
          decoded is Map<String, dynamic> &&
          decoded.containsKey('data')) {
        data = decoded['data'] as List<dynamic>;
        // Override data source from meta if available
        if (decoded.containsKey('meta')) {
          final meta = decoded['meta'] as Map<String, dynamic>;
          if (meta.containsKey('source')) {
            dataSource = meta['source'] as String;
          }
        }
      } else if (decoded is List) {
        data = decoded;
      } else {
        throw YahooException(
            'Invalid data format for $symbol $timeframe: expected array, got ${decoded.runtimeType}. Response: ${decoded.toString().substring(0, decoded.toString().length > 200 ? 200 : decoded.toString().length)}');
      }

      // Log number of received candles and source
      debugPrint(
          'YahooProto: Received ${data.length} candles for $symbol $timeframe from $dataSource');

      if (data.isEmpty) {
        // For large timeframes on weekends there may be no fresh data
        String hint = '';
        if (timeframe == '4h' || timeframe == '1d') {
          final now = DateTime.now();
          final dayOfWeek = now.weekday; // 1 = Monday, 7 = Sunday
          if (dayOfWeek == 6 || dayOfWeek == 7) {
            hint =
                ' Markets are closed on weekends. For 4h and 1d timeframes, Yahoo Finance may not return fresh data on weekends.';
          } else {
            hint =
                ' For 4h and 1d timeframes, data for a longer period is required.';
          }
        }
        throw YahooException(
            'Server returned empty data array for $symbol $timeframe. Possibly no data for requested period.$hint');
      }

      // Support two formats:
      // 1. Array of objects: [{timestamp, open, high, low, close, volume}, ...]
      // 2. Array of arrays: [[ts, open, high, low, close, volume], ...]
      final candles = data.map((e) {
        if (e is Map<String, dynamic>) {
          // Object format
          final timestamp = e['timestamp'];
          final open = e['open'];
          final high = e['high'];
          final low = e['low'];
          final close = e['close'];
          final volume = e['volume'];

          return CandleData(
            timestamp: timestamp is num ? timestamp.toInt() : 0,
            open: open is num ? open.toDouble() : 0.0,
            high: high is num ? high.toDouble() : 0.0,
            low: low is num ? low.toDouble() : 0.0,
            close: close is num ? close.toDouble() : 0.0,
            volume: volume is num ? volume.toDouble() : 0.0,
          );
        } else if (e is List) {
          // Array format (backward compatibility)
          final list = e.cast<num>();
          return CandleData(
            timestamp: list[0].toInt(),
            open: list[1].toDouble(),
            high: list[2].toDouble(),
            low: list[3].toDouble(),
            close: list[4].toDouble(),
            volume: list.length > 5 ? list[5].toDouble() : 0.0,
          );
        } else {
          throw YahooException(
              'Invalid candle element format: expected object or array, got ${e.runtimeType}');
        }
      }).toList();

      // Save to client-side cache for future requests
      if (candles.isNotEmpty) {
        DataCache.setCandles(cacheKey, candles);
      }

      return (candles, dataSource);
    } catch (e) {
      throw YahooException('Error getting data: $e');
    }
  }

  /// Get candles for symbol (backward compatibility)
  Future<List<CandleData>> fetchCandles(
    String symbol,
    String timeframe, {
    int? since,
    int limit = 1000,
  }) async {
    final (candles, _) = await fetchCandlesWithSource(
      symbol,
      timeframe,
      since: since,
      limit: limit,
    );
    return candles;
  }

  /// Get current price
  Future<double> fetchCurrentPrice(String symbol) async {
    try {
      final uri = Uri.parse('$endpoint/yf/quote').replace(
        queryParameters: {'symbol': symbol},
      );

      final response = await _client.get(
        uri,
        headers: {'accept': 'application/json'},
      ).timeout(_requestTimeout, onTimeout: () {
        throw YahooException('Request timeout');
      });

      if (response.statusCode != 200) {
        throw YahooException('YF quote $symbol ${response.statusCode}');
      }

      final decoded = json.decode(response.body);

      // Check for server error
      if (decoded is Map && decoded.containsKey('error')) {
        throw YahooException(decoded['error'] ?? 'Server error');
      }

      if (decoded is! Map<String, dynamic> || !decoded.containsKey('price')) {
        throw YahooException(
            'Invalid data format: expected object with price field');
      }

      final price = decoded['price'];
      if (price is! num) {
        throw YahooException('Price field must be a number');
      }
      return price.toDouble();
    } catch (e) {
      throw YahooException('Error getting price: $e');
    }
  }

  /// Get symbol information
  Future<SymbolInfo> fetchSymbolInfo(String symbol) async {
    try {
      final uri = Uri.parse('$endpoint/yf/info').replace(
        queryParameters: {'symbol': symbol},
      );

      final response = await _client.get(
        uri,
        headers: {'accept': 'application/json'},
      ).timeout(_requestTimeout, onTimeout: () {
        throw YahooException('Request timeout');
      });

      if (response.statusCode != 200) {
        throw YahooException('YF info $symbol ${response.statusCode}');
      }

      final decoded = json.decode(response.body);

      // Check for server error
      if (decoded is Map && decoded.containsKey('error')) {
        throw YahooException(decoded['error'] ?? 'Server error');
      }

      if (decoded is! Map<String, dynamic>) {
        throw YahooException('Invalid data format: expected object');
      }

      final data = decoded;
      return SymbolInfo(
        symbol: symbol,
        name: data['name'] ?? symbol,
        type: data['type'] ?? 'unknown',
        currency: data['currency'] ?? 'USD',
        exchange: data['exchange'] ?? 'Unknown',
      );
    } catch (e) {
      throw YahooException('Error getting information: $e');
    }
  }

  /// Search symbols
  Future<List<SymbolInfo>> searchSymbols(String query) async {
    try {
      final uri = Uri.parse('$endpoint/yf/search').replace(
        queryParameters: {'q': query},
      );

      final response = await _client.get(
        uri,
        headers: {'accept': 'application/json'},
      ).timeout(_requestTimeout, onTimeout: () {
        throw YahooException('Request timeout');
      });

      if (response.statusCode != 200) {
        throw YahooException('YF search $query ${response.statusCode}');
      }

      final decoded = json.decode(response.body);

      // Check for server error
      if (decoded is Map && decoded.containsKey('error')) {
        throw YahooException(decoded['error'] ?? 'Server error');
      }

      // Check that it's an array
      if (decoded is! List) {
        throw YahooException(
            'Invalid data format: expected array, got ${decoded.runtimeType}');
      }

      final data = decoded;
      return data.map<SymbolInfo>((e) {
        if (e is! Map<String, dynamic>) {
          throw YahooException(
              'Invalid element format: expected object, got ${e.runtimeType}');
        }
        return SymbolInfo.fromJson(e);
      }).toList();
    } catch (e) {
      throw YahooException('Error searching: $e');
    }
  }

  /// Get curated popular symbols list (cached in-app).
  Future<List<SymbolInfo>> fetchPopularSymbols() async {
    return popularSymbols;
  }

  void dispose() {
    _client.close();
  }
}

/// Candle data
class CandleData {
  final int timestamp;
  final double open;
  final double high;
  final double low;
  final double close;
  final double volume;

  CandleData({
    required this.timestamp,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.volume,
  });

  Map<String, dynamic> toJson() => {
        'timestamp': timestamp,
        'open': open,
        'high': high,
        'low': low,
        'close': close,
        'volume': volume,
      };

  factory CandleData.fromJson(Map<String, dynamic> json) => CandleData(
        timestamp: json['timestamp'],
        open: json['open'].toDouble(),
        high: json['high'].toDouble(),
        low: json['low'].toDouble(),
        close: json['close'].toDouble(),
        volume: json['volume'].toDouble(),
      );
}

/// Symbol information
class SymbolInfo {
  final String symbol;
  final String name;
  final String type;
  final String currency;
  final String exchange;

  const SymbolInfo({
    required this.symbol,
    required this.name,
    required this.type,
    required this.currency,
    required this.exchange,
  });

  Map<String, dynamic> toJson() => {
        'symbol': symbol,
        'name': name,
        'type': type,
        'currency': currency,
        'exchange': exchange,
      };

  factory SymbolInfo.fromJson(Map<String, dynamic> json) => SymbolInfo(
        symbol: json['symbol'],
        name: json['name'],
        type: json['type'],
        currency: json['currency'],
        exchange: json['exchange'],
      );
}

extension SymbolInfoDisplay on SymbolInfo {
  String get displayType {
    final normalized = type.toLowerCase();
    switch (normalized) {
      case 'equity':
      case 'stock':
        return 'Stock';
      case 'etf':
        return 'ETF';
      case 'index':
        return 'Index';
      case 'crypto':
      case 'cryptocurrency':
        return 'Crypto';
      case 'currency':
      case 'forex':
        return 'FX';
      case 'commodity':
        return 'Commodity';
      case 'future':
        return 'Future';
      case 'bond':
        return 'Bond';
      default:
        return type.isEmpty ? 'Asset' : type;
    }
  }

  String get shortExchange {
    if (exchange.isEmpty || exchange == 'Unknown') return '';
    return exchange;
  }
}

/// Yahoo Finance exception
class YahooException implements Exception {
  final String message;
  YahooException(this.message);

  @override
  String toString() => 'YahooException: $message';
}

/// Data cache
class DataCache {
  static final Map<String, List<CandleData>> _candlesCache = {};
  static final Map<String, double> _priceCache = {};
  static final Map<String, SymbolInfo> _infoCache = {};

  static const int _maxCacheSize = 100;
  // Client cache: 2 minutes for quick display, but always refresh on app open
  // Server cache is 60 seconds, ensuring fresh data when requested
  static const Duration _cacheExpiry = Duration(minutes: 2);
  static final Map<String, DateTime> _cacheTimestamps = {};

  static List<CandleData>? getCandles(String key) {
    if (_isExpired(key)) return null;
    return _candlesCache[key];
  }

  static DateTime? getCacheTimestamp(String key) {
    return _cacheTimestamps[key];
  }

  static void setCandles(String key, List<CandleData> candles) {
    _cleanupCache();
    _candlesCache[key] = candles;
    _cacheTimestamps[key] = DateTime.now();
  }

  static double? getPrice(String symbol) {
    if (_isExpired(symbol)) return null;
    return _priceCache[symbol];
  }

  static void setPrice(String symbol, double price) {
    _priceCache[symbol] = price;
    _cacheTimestamps[symbol] = DateTime.now();
  }

  static SymbolInfo? getInfo(String symbol) {
    if (_isExpired(symbol)) return null;
    return _infoCache[symbol];
  }

  static void setInfo(String symbol, SymbolInfo info) {
    _infoCache[symbol] = info;
    _cacheTimestamps[symbol] = DateTime.now();
  }

  static bool _isExpired(String key) {
    final timestamp = _cacheTimestamps[key];
    if (timestamp == null) return true;
    return DateTime.now().difference(timestamp) > _cacheExpiry;
  }

  static void clearCandles(String key) {
    _candlesCache.remove(key);
    _cacheTimestamps.remove(key);
  }

  static void _cleanupCache() {
    if (_candlesCache.length > _maxCacheSize) {
      final keys = _candlesCache.keys.toList();
      for (int i = 0; i < keys.length - _maxCacheSize; i++) {
        _candlesCache.remove(keys[i]);
        _cacheTimestamps.remove(keys[i]);
      }
    }
  }

  static void clear() {
    _candlesCache.clear();
    _priceCache.clear();
    _infoCache.clear();
    _cacheTimestamps.clear();
  }
}
