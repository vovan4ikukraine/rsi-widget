import 'dart:async';

import 'package:flutter/foundation.dart';

import 'yahoo_proto.dart';

/// Singleton-style helper used across the app to provide curated suggestions,
/// debounce network searches and cache results for a short window.
class SymbolSearchService {
  SymbolSearchService(this._source,
      {this.debounce = const Duration(milliseconds: 280),
      this.cacheTtl = const Duration(minutes: 10)});

  final YahooProtoSource _source;
  final Duration debounce;
  final Duration cacheTtl;

  Future<List<SymbolInfo>>? _popularFuture;
  final Map<String, List<SymbolInfo>> _cache = {};
  final Map<String, DateTime> _cacheTimestamps = {};
  int _searchToken = 0;

  Future<List<SymbolInfo>> getPopularSymbols() {
    return _popularFuture ??= _source.fetchPopularSymbols();
  }

  Future<List<SymbolInfo>> resolveSuggestions(String query) async {
    final trimmed = query.trim();
    final popular = await getPopularSymbols();

    if (trimmed.isEmpty) {
      return popular.take(40).toList();
    }

    final normalized = trimmed.toUpperCase();

    if (normalized.length == 1) {
      return _filterPopular(popular, normalized).take(25).toList();
    }

    if (normalized.length < 3) {
      final upper = normalized;
      final matches = _filterPopular(popular, upper).take(25).toList();
      if (matches.isNotEmpty) {
        return matches;
      }
      // Also try lowercase for name matching
      final lowerMatches =
          _filterPopular(popular, trimmed.toLowerCase()).take(25).toList();
      if (lowerMatches.isNotEmpty) {
        return lowerMatches;
      }
      return _filterPopular(popular, upper).take(25).toList();
    }

    final cached = _cache[normalized];
    if (cached != null && !_isExpired(normalized)) {
      return cached;
    }

    final token = ++_searchToken;
    await Future.delayed(debounce);
    if (token != _searchToken) {
      // A more recent query was issued, cancel this result.
      return const [];
    }

    List<SymbolInfo> merged = [];
    try {
      // First, try to find in popular symbols by name
      final popularMatches = _filterPopular(popular, normalized).toList();
      if (popularMatches.isNotEmpty) {
        merged.addAll(popularMatches);
      }

      // Also try lowercase name matching
      final lowerMatches =
          _filterPopular(popular, trimmed.toLowerCase()).toList();
      for (final match in lowerMatches) {
        if (!merged.any((m) => m.symbol == match.symbol)) {
          merged.add(match);
        }
      }

      // Then try remote search (Yahoo Finance API - searches by name automatically)
      var remote = await _source.searchSymbols(trimmed);
      if (remote.isEmpty && trimmed.toUpperCase() != trimmed) {
        remote = await _source.searchSymbols(normalized);
      }

      // Filter remote results by name match (Yahoo API already does this, but we prioritize exact matches)
      final remoteFiltered = remote.where((item) {
        final nameLower = item.name.toLowerCase();
        final symbolUpper = item.symbol.toUpperCase();
        final queryLower = trimmed.toLowerCase();
        final queryUpper = normalized;

        // Match by name (contains or starts with)
        if (nameLower.contains(queryLower) ||
            nameLower.startsWith(queryLower)) {
          return true;
        }

        // Match by symbol
        if (symbolUpper.contains(queryUpper) ||
            symbolUpper.startsWith(queryUpper)) {
          return true;
        }

        // Match by words in name
        final nameWords = nameLower.split(RegExp(r'[\s\-/]+'));
        for (final word in nameWords) {
          if (word.startsWith(queryLower) || queryLower.startsWith(word)) {
            return true;
          }
        }

        return false;
      }).toList();

      // Merge remote results with popular
      final remoteMerged = _mergeResults(remoteFiltered, popular, normalized);
      for (final item in remoteMerged) {
        if (!merged.any((m) => m.symbol == item.symbol)) {
          merged.add(item);
        }
      }

      if (merged.isEmpty) {
        merged = await _searchWithAlternates(trimmed, popular, normalized);
      }

      if (merged.isEmpty) {
        final fxHints = _generateFxSuggestions(normalized);
        if (fxHints.isNotEmpty) {
          merged = fxHints;
        }
      }

      if (merged.isEmpty) {
        final direct = await _tryFetchDirectInfo(trimmed);
        if (direct != null) {
          merged = [direct];
        }
      }

      if (merged.isEmpty) {
        merged =
            _mergeResults(const [], popular, normalized, suppressRemote: true);
      }

      if (merged.isEmpty) {
        merged = _filterPopular(popular, normalized).take(20).toList();
      }
    } catch (e) {
      merged =
          _mergeResults(const [], popular, normalized, suppressRemote: true);
      if (merged.isEmpty) {
        final fxHints = _generateFxSuggestions(normalized);
        if (fxHints.isNotEmpty) {
          merged = fxHints;
        }
      }
      if (merged.isEmpty) {
        final direct = await _tryFetchDirectInfo(trimmed);
        if (direct != null) {
          merged = [direct];
        } else {
          merged = _filterPopular(popular, normalized).take(20).toList();
        }
      }
    }

    _cache[normalized] = merged;
    _cacheTimestamps[normalized] = DateTime.now();
    return merged;
  }

  List<SymbolInfo> _mergeResults(
    List<SymbolInfo> remote,
    List<SymbolInfo> popular,
    String normalized, {
    bool suppressRemote = false,
  }) {
    final popularMatches = _filterPopular(popular, normalized);
    final List<SymbolInfo> combined = [
      ...popularMatches,
      if (!suppressRemote) ...remote,
    ];

    final fallback = _fallbackForQuery(normalized);
    if (fallback != null) {
      combined.insert(0, fallback);
    }

    final seen = <String>{};
    final result = <SymbolInfo>[];

    for (final item in combined) {
      final key = item.symbol.toUpperCase();
      if (seen.add(key)) {
        result.add(item);
      }
      if (result.length >= 40) break;
    }
    return result;
  }

  Iterable<SymbolInfo> _filterPopular(
    List<SymbolInfo> popular,
    String normalized,
  ) {
    if (normalized.isEmpty) {
      return popular;
    }

    // Also check against original query for case-insensitive name matching
    final queryLower = normalized.toLowerCase();

    return popular.where((item) {
      final symbol = item.symbol.toUpperCase();
      final name = item.name.toUpperCase();
      final nameLower = item.name.toLowerCase();

      // Check symbol
      if (symbol.startsWith(normalized) || symbol.contains(normalized)) {
        return true;
      }

      // Check name (exact match, starts with, contains)
      if (name.startsWith(normalized) ||
          name.contains(normalized) ||
          nameLower.startsWith(queryLower) ||
          nameLower.contains(queryLower)) {
        return true;
      }

      // Check if query matches any word in the name
      final nameWords = nameLower.split(RegExp(r'[\s\-/]+'));
      for (final word in nameWords) {
        if (word.startsWith(queryLower) || queryLower.startsWith(word)) {
          return true;
        }
      }

      return false;
    });
  }

  Future<List<SymbolInfo>> _searchWithAlternates(
    String query,
    List<SymbolInfo> popular,
    String normalized,
  ) async {
    final alternates = _generateAlternateQueries(query);
    final tried = <String>{query.toUpperCase()};

    for (final alt in alternates) {
      final upper = alt.toUpperCase();
      if (tried.contains(upper)) continue;
      tried.add(upper);

      try {
        final remote = await _source.searchSymbols(alt);
        final merged = _mergeResults(remote, popular, normalized);
        if (merged.isNotEmpty) {
          return merged;
        }
      } catch (e) {
        debugPrint('Alternate search for $alt failed: $e');
      }
    }
    return const [];
  }

  Future<SymbolInfo?> _tryFetchDirectInfo(String query) async {
    // Disabled direct API calls to /yf/info to avoid unnecessary 404 errors
    // If searchSymbols and popular symbols don't find it, we just return null or guess
    final trimmedQuery = query.trim();

    // Return fallback or guess without making API calls
    return _fallbackForQuery(trimmedQuery.toUpperCase()) ??
        _guessSymbolInfo(trimmedQuery);
  }

  SymbolInfo? _guessSymbolInfo(String raw) {
    final variants = _symbolVariants(raw);
    if (variants.isEmpty) return null;

    String candidate = variants.firstWhere(
      (v) => v.contains('-') || v.contains('='),
      orElse: () => variants.first,
    );
    candidate = candidate.toUpperCase();

    String type = 'equity';
    String currency = 'USD';
    String exchange = 'Unknown';
    String name = candidate;

    if (candidate.contains('=')) {
      type = 'currency';
      exchange = 'FX';
      final pair = candidate.split('=').first;
      if (pair.length >= 6) {
        currency = pair.substring(3);
      }
      name = '${pair.substring(0, 3)} / ${pair.substring(3)}';
    } else if (candidate.contains('-')) {
      type = 'crypto';
      final parts = candidate.split('-');
      if (parts.length > 1) {
        currency = parts.last;
        exchange = 'Crypto';
      }
      name = '${parts.first} / ${parts.last}';
    }

    return SymbolInfo(
      symbol: candidate,
      name: name,
      type: type,
      currency: currency,
      exchange: exchange,
    );
  }

  List<String> _generateAlternateQueries(String raw) {
    final upper = raw.toUpperCase();
    final alternates = <String>[];

    if (!upper.contains('-') && !upper.contains('=') && upper.length <= 5) {
      alternates.add('$upper-USD');
      alternates.add('$upper-USDT');
    }

    if (!upper.endsWith('=X') && upper.length == 6) {
      alternates.add('$upper=X');
      alternates
          .add('${upper.substring(0, 3)}/${upper.substring(3, upper.length)}');
    }

    if (upper.contains('/')) {
      final cleaned = upper.replaceAll('/', '');
      alternates.add(cleaned);
      alternates.add('$cleaned=X');
    }

    if (alternates.isEmpty || alternates.last != upper) {
      alternates.add(upper);
    }

    return alternates;
  }

  List<String> _symbolVariants(String raw) {
    // Skip processing if input is too long or contains spaces
    if (raw.length > 15 || raw.contains(' ')) {
      return [];
    }

    final upper = raw.toUpperCase();
    final variants = <String>{upper};

    // Only add variants for short symbols (likely actual tickers)
    if (upper.length <= 10) {
      if (!upper.endsWith('-USD')) {
        variants.add('$upper-USD');
      }
      if (!upper.endsWith('-USDT')) {
        variants.add('$upper-USDT');
      }
      if (!upper.endsWith('=X') && upper.length == 6) {
        variants.add('$upper=X');
      }
      if (upper.contains('/')) {
        final cleaned = upper.replaceAll('/', '');
        variants.add(cleaned);
        variants.add('$cleaned=X');
      }
    }

    return variants.toList();
  }

  List<SymbolInfo> _generateFxSuggestions(String normalized) {
    final lettersOnly = normalized.replaceAll(RegExp(r'[^A-Z]'), '');
    if (lettersOnly.length < 3) return const <SymbolInfo>[];
    final base = lettersOnly.substring(0, 3);
    if (!_fxCurrencies.contains(base)) return const <SymbolInfo>[];
    final remainder = lettersOnly.length > 3 ? lettersOnly.substring(3) : '';

    final suggestions = <SymbolInfo>[];
    for (final counter in _fxCurrencies) {
      if (counter == base) continue;
      if (remainder.isNotEmpty && !counter.startsWith(remainder)) continue;

      final symbol = '$base$counter=X';
      suggestions.add(
        SymbolInfo(
          symbol: symbol,
          name:
              '${_currencyNames[base] ?? base} / ${_currencyNames[counter] ?? counter}',
          type: 'currency',
          currency: counter,
          exchange: 'FX',
        ),
      );
      if (suggestions.length >= 20) break;
    }
    return suggestions;
  }

  SymbolInfo? _fallbackForQuery(String normalized) {
    if (normalized.isEmpty) return null;

    // Only use fallback map for known symbols (not name mappings)
    final cleaned = normalized.replaceAll(RegExp(r'[^A-Z0-9]'), '');
    final entry = _fallbackMap[cleaned];
    if (entry != null) {
      return entry;
    }

    if (normalized.endsWith('-USD')) {
      final base = normalized.replaceAll('-USD', '');
      final fallback = _fallbackMap[base];
      if (fallback != null) {
        return fallback;
      }
    }

    if (normalized.endsWith('=X')) {
      final base = normalized.replaceAll('=X', '');
      final fallback = _fallbackMap[base];
      if (fallback != null) {
        return fallback;
      }
    }

    for (final entry in _fallbackMap.entries) {
      final key = entry.key;
      if (key.startsWith(normalized) || normalized.startsWith(key)) {
        return entry.value;
      }
    }

    return null;
  }

  bool _isExpired(String key) {
    final ts = _cacheTimestamps[key];
    if (ts == null) return true;
    return DateTime.now().difference(ts) > cacheTtl;
  }

  void clearCache() {
    _cache.clear();
    _cacheTimestamps.clear();
  }

  /// Cancels all pending delayed searches. Call when the widget disposes.
  void cancelPending() {
    _searchToken++;
  }
}

final symbolSearchService = SymbolSearchService(yahooService);

// Fallback map for known symbols (only for direct symbol lookups, not name searches)
const Map<String, SymbolInfo> _fallbackMap = {
  // Commodities
  'GC=F': SymbolInfo(
    symbol: 'GC=F',
    name: 'Gold Futures',
    type: 'commodity',
    currency: 'USD',
    exchange: 'COMEX',
  ),
  'SI=F': SymbolInfo(
    symbol: 'SI=F',
    name: 'Silver Futures',
    type: 'commodity',
    currency: 'USD',
    exchange: 'COMEX',
  ),
  'CL=F': SymbolInfo(
    symbol: 'CL=F',
    name: 'Crude Oil Futures',
    type: 'commodity',
    currency: 'USD',
    exchange: 'NYMEX',
  ),
  'NG=F': SymbolInfo(
    symbol: 'NG=F',
    name: 'Natural Gas Futures',
    type: 'commodity',
    currency: 'USD',
    exchange: 'NYMEX',
  ),
  'ZC=F': SymbolInfo(
    symbol: 'ZC=F',
    name: 'Corn Futures',
    type: 'commodity',
    currency: 'USD',
    exchange: 'CBOT',
  ),
  'ZS=F': SymbolInfo(
    symbol: 'ZS=F',
    name: 'Soybean Futures',
    type: 'commodity',
    currency: 'USD',
    exchange: 'CBOT',
  ),

  // Cryptocurrencies
  'MATIC': SymbolInfo(
    symbol: 'POL28321-USD',
    name: 'Polygon (MATIC)',
    type: 'crypto',
    currency: 'USD',
    exchange: 'Crypto',
  ),
  'POLYGON': SymbolInfo(
    symbol: 'POL28321-USD',
    name: 'Polygon (MATIC)',
    type: 'crypto',
    currency: 'USD',
    exchange: 'Crypto',
  ),
  'APTOS': SymbolInfo(
    symbol: 'APT21794-USD',
    name: 'Aptos',
    type: 'crypto',
    currency: 'USD',
    exchange: 'Crypto',
  ),
  'APT': SymbolInfo(
    symbol: 'APT21794-USD',
    name: 'Aptos',
    type: 'crypto',
    currency: 'USD',
    exchange: 'Crypto',
  ),
  'BTC-USD': SymbolInfo(
    symbol: 'BTC-USD',
    name: 'Bitcoin',
    type: 'crypto',
    currency: 'USD',
    exchange: 'Crypto',
  ),
  'ETH-USD': SymbolInfo(
    symbol: 'ETH-USD',
    name: 'Ethereum',
    type: 'crypto',
    currency: 'USD',
    exchange: 'Crypto',
  ),
  'ZEC-USD': SymbolInfo(
    symbol: 'ZEC-USD',
    name: 'Zcash',
    type: 'crypto',
    currency: 'USD',
    exchange: 'Crypto',
  ),
  'XMR': SymbolInfo(
    symbol: 'XMR-USD',
    name: 'Monero',
    type: 'crypto',
    currency: 'USD',
    exchange: 'Crypto',
  ),
  'XMR-USD': SymbolInfo(
    symbol: 'XMR-USD',
    name: 'Monero',
    type: 'crypto',
    currency: 'USD',
    exchange: 'Crypto',
  ),
  'XRP': SymbolInfo(
    symbol: 'XRP-USD',
    name: 'XRP',
    type: 'crypto',
    currency: 'USD',
    exchange: 'Crypto',
  ),
  'ADA': SymbolInfo(
    symbol: 'ADA-USD',
    name: 'Cardano',
    type: 'crypto',
    currency: 'USD',
    exchange: 'Crypto',
  ),
  'SOL': SymbolInfo(
    symbol: 'SOL-USD',
    name: 'Solana',
    type: 'crypto',
    currency: 'USD',
    exchange: 'Crypto',
  ),
  'DOT': SymbolInfo(
    symbol: 'DOT-USD',
    name: 'Polkadot',
    type: 'crypto',
    currency: 'USD',
    exchange: 'Crypto',
  ),
  'MATIC-USD': SymbolInfo(
    symbol: 'POL28321-USD',
    name: 'Polygon (MATIC)',
    type: 'crypto',
    currency: 'USD',
    exchange: 'Crypto',
  ),
  'AVAX': SymbolInfo(
    symbol: 'AVAX-USD',
    name: 'Avalanche',
    type: 'crypto',
    currency: 'USD',
    exchange: 'Crypto',
  ),
  'ATOM': SymbolInfo(
    symbol: 'ATOM-USD',
    name: 'Cosmos',
    type: 'crypto',
    currency: 'USD',
    exchange: 'Crypto',
  ),
  'ARB': SymbolInfo(
    symbol: 'ARB11841-USD',
    name: 'Arbitrum',
    type: 'crypto',
    currency: 'USD',
    exchange: 'Crypto',
  ),
  'UNI': SymbolInfo(
    symbol: 'UNI7083-USD',
    name: 'Uniswap',
    type: 'crypto',
    currency: 'USD',
    exchange: 'Crypto',
  ),
  'UNI-USD': SymbolInfo(
    symbol: 'UNI7083-USD',
    name: 'Uniswap',
    type: 'crypto',
    currency: 'USD',
    exchange: 'Crypto',
  ),
  'UNISWAP': SymbolInfo(
    symbol: 'UNI7083-USD',
    name: 'Uniswap',
    type: 'crypto',
    currency: 'USD',
    exchange: 'Crypto',
  ),
  'APT-USD': SymbolInfo(
    symbol: 'APT21794-USD',
    name: 'Aptos',
    type: 'crypto',
    currency: 'USD',
    exchange: 'Crypto',
  ),
  'SUI': SymbolInfo(
    symbol: 'SUI20947-USD',
    name: 'Sui',
    type: 'crypto',
    currency: 'USD',
    exchange: 'Crypto',
  ),
  'SUI-USD': SymbolInfo(
    symbol: 'SUI20947-USD',
    name: 'Sui',
    type: 'crypto',
    currency: 'USD',
    exchange: 'Crypto',
  ),
  'NEAR': SymbolInfo(
    symbol: 'NEAR-USD',
    name: 'NEAR Protocol',
    type: 'crypto',
    currency: 'USD',
    exchange: 'Crypto',
  ),
  'LTC': SymbolInfo(
    symbol: 'LTC-USD',
    name: 'Litecoin',
    type: 'crypto',
    currency: 'USD',
    exchange: 'Crypto',
  ),
  'XLM': SymbolInfo(
    symbol: 'XLM-USD',
    name: 'Stellar',
    type: 'crypto',
    currency: 'USD',
    exchange: 'Crypto',
  ),
  'TRX': SymbolInfo(
    symbol: 'TRX-USD',
    name: 'TRON',
    type: 'crypto',
    currency: 'USD',
    exchange: 'Crypto',
  ),
  'SHIB': SymbolInfo(
    symbol: 'SHIB-USD',
    name: 'Shiba Inu',
    type: 'crypto',
    currency: 'USD',
    exchange: 'Crypto',
  ),
  'TIA': SymbolInfo(
    symbol: 'TIA-USD',
    name: 'Celestia',
    type: 'crypto',
    currency: 'USD',
    exchange: 'Crypto',
  ),
  'TIAUSD': SymbolInfo(
    symbol: 'TIA-USD',
    name: 'Celestia',
    type: 'crypto',
    currency: 'USD',
    exchange: 'Crypto',
  ),
  'CADCHF': SymbolInfo(
    symbol: 'CADCHF=X',
    name: 'Canadian Dollar / Swiss Franc',
    type: 'currency',
    currency: 'CHF',
    exchange: 'FX',
  ),
  'EURCZ': SymbolInfo(
    symbol: 'EURCZK=X',
    name: 'Euro / Czech Koruna',
    type: 'currency',
    currency: 'CZK',
    exchange: 'FX',
  ),
  'EURCZK': SymbolInfo(
    symbol: 'EURCZK=X',
    name: 'Euro / Czech Koruna',
    type: 'currency',
    currency: 'CZK',
    exchange: 'FX',
  ),
  'EURPL': SymbolInfo(
    symbol: 'EURPLN=X',
    name: 'Euro / Polish Zloty',
    type: 'currency',
    currency: 'PLN',
    exchange: 'FX',
  ),
  'EURPLN': SymbolInfo(
    symbol: 'EURPLN=X',
    name: 'Euro / Polish Zloty',
    type: 'currency',
    currency: 'PLN',
    exchange: 'FX',
  ),
  'USDPL': SymbolInfo(
    symbol: 'USDPLN=X',
    name: 'US Dollar / Polish Zloty',
    type: 'currency',
    currency: 'PLN',
    exchange: 'FX',
  ),
  'USDPLN': SymbolInfo(
    symbol: 'USDPLN=X',
    name: 'US Dollar / Polish Zloty',
    type: 'currency',
    currency: 'PLN',
    exchange: 'FX',
  ),
  'USDTRY': SymbolInfo(
    symbol: 'USDTRY=X',
    name: 'US Dollar / Turkish Lira',
    type: 'currency',
    currency: 'TRY',
    exchange: 'FX',
  ),
  'USDZAR': SymbolInfo(
    symbol: 'USDZAR=X',
    name: 'US Dollar / South African Rand',
    type: 'currency',
    currency: 'ZAR',
    exchange: 'FX',
  ),
  'USDBRL': SymbolInfo(
    symbol: 'USDBRL=X',
    name: 'US Dollar / Brazilian Real',
    type: 'currency',
    currency: 'BRL',
    exchange: 'FX',
  ),
  'EURHUF': SymbolInfo(
    symbol: 'EURHUF=X',
    name: 'Euro / Hungarian Forint',
    type: 'currency',
    currency: 'HUF',
    exchange: 'FX',
  ),
  'EURRON': SymbolInfo(
    symbol: 'EURRON=X',
    name: 'Euro / Romanian Leu',
    type: 'currency',
    currency: 'RON',
    exchange: 'FX',
  ),
  'SHIBUSD': SymbolInfo(
    symbol: 'SHIB-USD',
    name: 'Shiba Inu',
    type: 'crypto',
    currency: 'USD',
    exchange: 'Crypto',
  ),
};

const List<String> _fxCurrencies = [
  'USD',
  'EUR',
  'GBP',
  'JPY',
  'AUD',
  'CAD',
  'CHF',
  'NZD',
  'CNH',
  'CNY',
  'PLN',
  'CZK',
  'HUF',
  'RON',
  'TRY',
  'ZAR',
  'BRL',
  'MXN',
  'SEK',
  'NOK',
  'DKK',
  'SGD',
  'HKD',
];

const Map<String, String> _currencyNames = {
  'USD': 'US Dollar',
  'EUR': 'Euro',
  'GBP': 'British Pound',
  'JPY': 'Japanese Yen',
  'AUD': 'Australian Dollar',
  'CAD': 'Canadian Dollar',
  'CHF': 'Swiss Franc',
  'NZD': 'New Zealand Dollar',
  'CNH': 'Chinese Yuan (Offshore)',
  'CNY': 'Chinese Yuan',
  'PLN': 'Polish Złoty',
  'CZK': 'Czech Koruna',
  'HUF': 'Hungarian Forint',
  'RON': 'Romanian Leu',
  'TRY': 'Turkish Lira',
  'ZAR': 'South African Rand',
  'BRL': 'Brazilian Real',
  'MXN': 'Mexican Peso',
  'SEK': 'Swedish Krona',
  'NOK': 'Norwegian Krone',
  'DKK': 'Danish Krone',
  'SGD': 'Singapore Dollar',
  'HKD': 'Hong Kong Dollar',
};
