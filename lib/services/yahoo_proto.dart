import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

final yahooService =
    YahooProtoSource('https://rsi-workers.vovan4ikukraine.workers.dev');

/// Адаптер для получения данных от Yahoo Finance через прокси
class YahooProtoSource {
  final String endpoint;
  final http.Client _client = http.Client();

  YahooProtoSource(this.endpoint);

  /// Получение свечей для символа
  Future<List<CandleData>> fetchCandles(
    String symbol,
    String timeframe, {
    int? since,
    int limit = 1000,
  }) async {
    try {
      final uri = Uri.parse('$endpoint/yf/candles').replace(
        queryParameters: {
          'symbol': symbol,
          'tf': timeframe,
          if (since != null) 'since': since.toString(),
          'limit': limit.toString(),
        },
      );

      final response = await _client.get(
        uri,
        headers: {'accept': 'application/json'},
      );

      if (response.statusCode != 200) {
        final errorBody = response.body;
        throw YahooException(
            'Ошибка HTTP ${response.statusCode} для $symbol $timeframe: $errorBody');
      }

      final decoded = json.decode(response.body);

      // Проверка на ошибку от сервера
      if (decoded is Map && decoded.containsKey('error')) {
        final errorMsg = decoded['error'];
        throw YahooException(
            'Сервер вернул ошибку для $symbol $timeframe: $errorMsg');
      }

      // Проверка, что это массив
      if (decoded is! List) {
        throw YahooException(
            'Неверный формат данных для $symbol $timeframe: ожидается массив, получен ${decoded.runtimeType}. Ответ: ${decoded.toString().substring(0, decoded.toString().length > 200 ? 200 : decoded.toString().length)}');
      }

      final data = decoded;

      // Логируем количество полученных свечей
      debugPrint(
          'YahooProto: Получено ${data.length} свечей для $symbol $timeframe');

      if (data.isEmpty) {
        // Для больших таймфреймов в выходные дни может не быть свежих данных
        String hint = '';
        if (timeframe == '4h' || timeframe == '1d') {
          final now = DateTime.now();
          final dayOfWeek = now.weekday; // 1 = Monday, 7 = Sunday
          if (dayOfWeek == 6 || dayOfWeek == 7) {
            hint =
                ' Рынки закрыты в выходные дни. Для таймфреймов 4h и 1d Yahoo Finance может не возвращать свежие данные в выходные.';
          } else {
            hint =
                ' Для таймфреймов 4h и 1d требуются данные за более длительный период.';
          }
        }
        throw YahooException(
            'Сервер вернул пустой массив данных для $symbol $timeframe. Возможно, нет данных за запрошенный период.$hint');
      }

      // Поддержка двух форматов:
      // 1. Массив объектов: [{timestamp, open, high, low, close, volume}, ...]
      // 2. Массив массивов: [[ts, open, high, low, close, volume], ...]
      return data.map((e) {
        if (e is Map<String, dynamic>) {
          // Формат объекта
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
          // Формат массива (обратная совместимость)
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
              'Неверный формат элемента свечи: ожидается объект или массив, получен ${e.runtimeType}');
        }
      }).toList();
    } catch (e) {
      throw YahooException('Ошибка получения данных: $e');
    }
  }

  /// Получение текущей цены
  Future<double> fetchCurrentPrice(String symbol) async {
    try {
      final uri = Uri.parse('$endpoint/yf/quote').replace(
        queryParameters: {'symbol': symbol},
      );

      final response = await _client.get(
        uri,
        headers: {'accept': 'application/json'},
      );

      if (response.statusCode != 200) {
        throw YahooException('YF quote $symbol ${response.statusCode}');
      }

      final decoded = json.decode(response.body);

      // Проверка на ошибку от сервера
      if (decoded is Map && decoded.containsKey('error')) {
        throw YahooException(decoded['error'] ?? 'Ошибка сервера');
      }

      if (decoded is! Map<String, dynamic> || !decoded.containsKey('price')) {
        throw YahooException(
            'Неверный формат данных: ожидается объект с полем price');
      }

      final price = decoded['price'];
      if (price is! num) {
        throw YahooException('Поле price должно быть числом');
      }
      return price.toDouble();
    } catch (e) {
      throw YahooException('Ошибка получения цены: $e');
    }
  }

  /// Получение информации о символе
  Future<SymbolInfo> fetchSymbolInfo(String symbol) async {
    try {
      final uri = Uri.parse('$endpoint/yf/info').replace(
        queryParameters: {'symbol': symbol},
      );

      final response = await _client.get(
        uri,
        headers: {'accept': 'application/json'},
      );

      if (response.statusCode != 200) {
        throw YahooException('YF info $symbol ${response.statusCode}');
      }

      final decoded = json.decode(response.body);

      // Проверка на ошибку от сервера
      if (decoded is Map && decoded.containsKey('error')) {
        throw YahooException(decoded['error'] ?? 'Ошибка сервера');
      }

      if (decoded is! Map<String, dynamic>) {
        throw YahooException('Неверный формат данных: ожидается объект');
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
      throw YahooException('Ошибка получения информации: $e');
    }
  }

  /// Поиск символов
  Future<List<SymbolInfo>> searchSymbols(String query) async {
    try {
      final uri = Uri.parse('$endpoint/yf/search').replace(
        queryParameters: {'q': query},
      );

      final response = await _client.get(
        uri,
        headers: {'accept': 'application/json'},
      );

      if (response.statusCode != 200) {
        throw YahooException('YF search $query ${response.statusCode}');
      }

      final decoded = json.decode(response.body);

      // Проверка на ошибку от сервера
      if (decoded is Map && decoded.containsKey('error')) {
        throw YahooException(decoded['error'] ?? 'Ошибка сервера');
      }

      // Проверка, что это массив
      if (decoded is! List) {
        throw YahooException(
            'Неверный формат данных: ожидается массив, получен ${decoded.runtimeType}');
      }

      final data = decoded;
      return data.map<SymbolInfo>((e) {
        if (e is! Map<String, dynamic>) {
          throw YahooException(
              'Неверный формат элемента: ожидается объект, получен ${e.runtimeType}');
        }
        return SymbolInfo.fromJson(e);
      }).toList();
    } catch (e) {
      throw YahooException('Ошибка поиска: $e');
    }
  }

  /// Получение популярных символов
  Future<List<String>> fetchPopularSymbols() async {
    return [
      // Акции США - Технологии
      'AAPL', 'MSFT', 'GOOGL', 'GOOG', 'AMZN', 'TSLA', 'META', 'NVDA', 'NFLX',
      'AMD', 'INTC', 'CRM', 'ADBE', 'PYPL', 'UBER', 'SQ', 'NOW', 'SNOW',
      'PLTR', 'RBLX', 'COIN', 'HOOD', 'SOFI', 'AFRM', 'UPST',

      // Акции США - Финансы
      'JPM', 'BAC', 'WFC', 'GS', 'MS', 'C', 'BLK', 'SCHW',

      // Акции США - Потребительские товары
      'WMT', 'TGT', 'HD', 'NKE', 'SBUX', 'MCD', 'DIS', 'NFLX',

      // Акции США - Энергетика
      'XOM', 'CVX', 'COP', 'SLB', 'EOG',

      // Акции США - Здравоохранение
      'JNJ', 'PFE', 'UNH', 'ABBV', 'TMO', 'ABT', 'MRK',

      // Индексы
      '^GSPC', // S&P 500
      '^DJI', // Dow Jones
      '^IXIC', // NASDAQ
      '^RUT', // Russell 2000

      // Форекс - Major pairs
      'EURUSD=X', 'GBPUSD=X', 'USDJPY=X', 'AUDUSD=X', 'USDCAD=X',
      'USDCHF=X', 'NZDUSD=X', 'EURGBP=X', 'EURJPY=X', 'GBPJPY=X',
      'EURCHF=X', 'AUDJPY=X', 'NZDJPY=X', 'CADJPY=X', 'CHFJPY=X',

      // Форекс - Cross pairs
      'EURCAD=X', 'EURAUD=X', 'EURNZD=X', 'GBPCAD=X', 'GBPAUD=X',
      'GBPNZD=X', 'AUDCAD=X', 'AUDNZD=X', 'CADCHF=X',

      // Криптовалюты
      'BTC-USD', 'ETH-USD', 'BNB-USD', 'ADA-USD', 'SOL-USD',
      'XRP-USD', 'DOGE-USD', 'DOT-USD', 'MATIC-USD', 'AVAX-USD',
      'LINK-USD', 'UNI-USD', 'ATOM-USD', 'ALGO-USD', 'VET-USD',

      // Товары
      'GC=F', // Gold
      'SI=F', // Silver
      'CL=F', // Crude Oil
      'NG=F', // Natural Gas
      'ZC=F', // Corn
      'ZS=F', // Soybeans

      // ETF
      'SPY', // S&P 500 ETF
      'QQQ', // NASDAQ ETF
      'DIA', // Dow ETF
      'IWM', // Russell 2000 ETF
      'GLD', // Gold ETF
      'SLV', // Silver ETF
    ];
  }

  void dispose() {
    _client.close();
  }
}

/// Данные свечи
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

/// Информация о символе
class SymbolInfo {
  final String symbol;
  final String name;
  final String type;
  final String currency;
  final String exchange;

  SymbolInfo({
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

/// Исключение Yahoo Finance
class YahooException implements Exception {
  final String message;
  YahooException(this.message);

  @override
  String toString() => 'YahooException: $message';
}

/// Кэш для данных
class DataCache {
  static final Map<String, List<CandleData>> _candlesCache = {};
  static final Map<String, double> _priceCache = {};
  static final Map<String, SymbolInfo> _infoCache = {};

  static const int _maxCacheSize = 100;
  static const Duration _cacheExpiry = Duration(minutes: 5);
  static final Map<String, DateTime> _cacheTimestamps = {};

  static List<CandleData>? getCandles(String key) {
    if (_isExpired(key)) return null;
    return _candlesCache[key];
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
