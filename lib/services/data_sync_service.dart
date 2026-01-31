import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import '../di/app_container.dart';
import '../models.dart';
import '../repositories/i_alert_repository.dart';
import '../repositories/i_watchlist_repository.dart';
import '../utils/preferences_storage.dart';
import 'user_service.dart';
import 'auth_service.dart';
import 'alert_sync_service.dart';

/// Service for syncing user data (watchlist, chart preferences) with server
class DataSyncService {
  static String get _baseUrl => AppConfig.apiBaseUrl;

  /// Save chart preferences to local cache (for anonymous mode)
  static Future<void> savePreferencesToCache({
    String? symbol,
    String? timeframe,
    int? rsiPeriod,
    double? lowerLevel,
    double? upperLevel,
  }) async {
    final prefs = await PreferencesStorage.instance;
    if (symbol != null) {
      await prefs.setString('anonymous_home_selected_symbol', symbol);
    }
    if (timeframe != null) {
      await prefs.setString('anonymous_home_selected_timeframe', timeframe);
    }
    if (rsiPeriod != null) {
      await prefs.setInt('anonymous_home_rsi_period', rsiPeriod);
    }
    if (lowerLevel != null) {
      await prefs.setDouble('anonymous_home_lower_level', lowerLevel);
    }
    if (upperLevel != null) {
      await prefs.setDouble('anonymous_home_upper_level', upperLevel);
    }
  }

  /// Load chart preferences from cache (for anonymous mode)
  static Future<Map<String, dynamic>> loadPreferencesFromCache() async {
    final prefs = await PreferencesStorage.instance;
    return {
      'symbol': prefs.getString('anonymous_home_selected_symbol'),
      'timeframe': prefs.getString('anonymous_home_selected_timeframe'),
      'rsiPeriod': prefs.getInt('anonymous_home_rsi_period'),
      'lowerLevel': prefs.getDouble('anonymous_home_lower_level'),
      'upperLevel': prefs.getDouble('anonymous_home_upper_level'),
    };
  }

  /// Save anonymous watchlist to cache
  static Future<void> saveWatchlistToCache() async {
    try {
      final repo = sl<IWatchlistRepository>();
      final items = await repo.getAll();
      final prefs = await PreferencesStorage.instance;
      final symbols = items.map((item) => item.symbol).toList();
      await prefs.setStringList('anonymous_watchlist', symbols);
      
      // Also seed widget symbols so Android widget works for anonymous users
      await seedWidgetSymbols(symbols);
      
      if (kDebugMode) {
        debugPrint(
            'DataSyncService: Saved ${symbols.length} items to anonymous watchlist cache');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('DataSyncService: Error saving watchlist to cache: $e');
      }
    }
  }

  /// Load anonymous watchlist from cache
  static Future<List<String>> loadWatchlistFromCache() async {
    try {
      final prefs = await PreferencesStorage.instance;
      return prefs.getStringList('anonymous_watchlist') ?? [];
    } catch (e) {
      if (kDebugMode) {
        debugPrint('DataSyncService: Error loading watchlist from cache: $e');
      }
      return [];
    }
  }

  /// Restore anonymous watchlist from cache to database
  static Future<void> restoreWatchlistFromCache() async {
    try {
      final symbols = await loadWatchlistFromCache();
      final now = DateTime.now().millisecondsSinceEpoch;
      final items = symbols
          .map(
            (symbol) => WatchlistItem()
              ..symbol = symbol
              ..createdAt = now,
          )
          .toList();
      final repo = sl<IWatchlistRepository>();
      await repo.replaceAll(items);

      if (kDebugMode) {
        debugPrint(
            'DataSyncService: Restored ${symbols.length} items from anonymous watchlist cache');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('DataSyncService: Error restoring watchlist from cache: $e');
      }
    }
  }

  /// Save anonymous alerts to cache
  static Future<void> saveAlertsToCache() async {
    try {
      final repo = sl<IAlertRepository>();
      final alerts = await repo.getAllAlerts();
      final prefs = await PreferencesStorage.instance;

      // Save only anonymous alerts (those without remoteId)
      final anonymousAlerts = alerts.where((a) => a.remoteId == null).toList();

      // Save alerts as JSON array
      final alertsJson = anonymousAlerts
          .map((alert) => {
                'id': alert.id,
                'symbol': alert.symbol,
                'timeframe': alert.timeframe,
                'indicator': alert.indicator,
                'period': alert.period,
                'indicatorParams': alert.indicatorParams,
                'rsiPeriod': alert.period, // Keep for backward compatibility
                'levels': alert.levels,
                'mode': alert.mode,
                'cooldownSec': alert.cooldownSec,
                'active': alert.active,
                'createdAt': alert.createdAt,
                'description': alert.description,
                'repeatable': alert.repeatable,
                'soundEnabled': alert.soundEnabled,
                'customSound': alert.customSound,
              })
          .toList();

      await prefs.setString('anonymous_alerts', jsonEncode(alertsJson));

      // Also save alert states for anonymous alerts
      final alertIds = anonymousAlerts.map((a) => a.id).toSet();
      final states = await repo.getAllAlertStates();
      final anonymousStates =
          states.where((s) => alertIds.contains(s.ruleId)).toList();
      final statesJson = anonymousStates
          .map((state) => {
                'id': state.id,
                'ruleId': state.ruleId,
                'lastIndicatorValue': state.lastIndicatorValue,
                'indicatorState': state.indicatorStateJson,
                'lastRsi':
                    state.lastIndicatorValue, // Keep for backward compatibility
                'lastBarTs': state.lastBarTs,
                'lastFireTs': state.lastFireTs,
                'lastSide': state.lastSide,
                'wasAboveUpper': state.wasAboveUpper,
                'wasBelowLower': state.wasBelowLower,
                'lastAu': state.indicatorState?['au'] as double?,
                'lastAd': state.indicatorState?['ad'] as double?,
              })
          .toList();
      await prefs.setString('anonymous_alert_states', jsonEncode(statesJson));

      // Also save alert events for anonymous alerts
      final events = await repo.getAllAlertEvents();
      final anonymousEvents =
          events.where((e) => alertIds.contains(e.ruleId)).toList();
      final eventsJson = anonymousEvents
          .map((event) => {
                'id': event.id,
                'ruleId': event.ruleId,
                'ts': event.ts,
                'indicatorValue': event.indicatorValue,
                'indicator': event.indicator,
                'rsi': event.indicatorValue, // Keep for backward compatibility
                'level': event.level,
                'side': event.side,
                'barTs': event.barTs,
                'symbol': event.symbol,
                'message': event.message,
                'isRead': event.isRead,
              })
          .toList();
      await prefs.setString('anonymous_alert_events', jsonEncode(eventsJson));

      if (kDebugMode) {
        debugPrint(
            'DataSyncService: Saved ${anonymousAlerts.length} alerts, ${anonymousStates.length} states, ${anonymousEvents.length} events to anonymous cache');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('DataSyncService: Error saving alerts to cache: $e');
      }
    }
  }

  /// Restore anonymous alerts from cache to database
  static Future<void> restoreAlertsFromCache() async {
    try {
      final prefs = await PreferencesStorage.instance;

      final alertsJsonStr = prefs.getString('anonymous_alerts');
      if (alertsJsonStr == null) {
        if (kDebugMode) {
          debugPrint('DataSyncService: No anonymous alerts in cache');
        }
        return;
      }

      final alertsJson = jsonDecode(alertsJsonStr) as List<dynamic>;
      final alertsToRestore = <(int, AlertRule)>[];
      for (final alertData in alertsJson) {
        final oldId = alertData['id'] as int;
        final alert = AlertRule()
          ..symbol = alertData['symbol'] as String
          ..timeframe = alertData['timeframe'] as String
          ..indicator = alertData['indicator'] as String? ?? 'rsi'
          ..period = alertData['period'] as int? ??
              alertData['rsiPeriod'] as int? ??
              14
          ..indicatorParams = alertData['indicatorParams'] != null
              ? Map<String, dynamic>.from(alertData['indicatorParams'] as Map)
              : null
          ..levels = (alertData['levels'] as List<dynamic>)
              .map((e) => (e as num).toDouble())
              .toList()
          ..mode = alertData['mode'] as String
          ..cooldownSec = alertData['cooldownSec'] as int
          ..active = alertData['active'] as bool
          ..createdAt = alertData['createdAt'] as int
          ..description = alertData['description'] as String?
          ..repeatable = alertData['repeatable'] as bool? ?? true
          ..soundEnabled = alertData['soundEnabled'] as bool? ?? true
          ..customSound = alertData['customSound'] as String?
          ..remoteId = null;
        alertsToRestore.add((oldId, alert));
      }

      final statesToRestore = <(int, AlertState)>[];
      final statesJsonStr = prefs.getString('anonymous_alert_states');
      if (statesJsonStr != null) {
        final statesJson = jsonDecode(statesJsonStr) as List<dynamic>;
        for (final stateData in statesJson) {
          final oldRuleId = stateData['ruleId'] as int;
          final state = AlertState()
            ..ruleId = 0
            ..lastIndicatorValue =
                stateData['lastIndicatorValue'] as double? ??
                    stateData['lastRsi'] as double?
            ..indicatorStateJson = stateData['indicatorState'] as String? ??
                (stateData['lastAu'] != null || stateData['lastAd'] != null
                    ? jsonEncode({
                        'au': stateData['lastAu'] as double?,
                        'ad': stateData['lastAd'] as double?,
                      })
                    : null)
            ..lastBarTs = stateData['lastBarTs'] as int?
            ..lastFireTs = stateData['lastFireTs'] as int?
            ..lastSide = stateData['lastSide'] as String?
            ..wasAboveUpper = stateData['wasAboveUpper'] as bool?
            ..wasBelowLower = stateData['wasBelowLower'] as bool?;
          statesToRestore.add((oldRuleId, state));
        }
      }

      final eventsToRestore = <(int, AlertEvent)>[];
      final eventsJsonStr = prefs.getString('anonymous_alert_events');
      if (eventsJsonStr != null) {
        final eventsJson = jsonDecode(eventsJsonStr) as List<dynamic>;
        for (final eventData in eventsJson) {
          final oldRuleId = eventData['ruleId'] as int;
          final event = AlertEvent()
            ..ruleId = 0
            ..ts = eventData['ts'] as int
            ..indicatorValue = eventData['indicatorValue'] as double? ??
                eventData['rsi'] as double
            ..indicator = eventData['indicator'] as String? ?? 'rsi'
            ..level = eventData['level'] as double?
            ..side = eventData['side'] as String?
            ..barTs = eventData['barTs'] as int?
            ..symbol = eventData['symbol'] as String
            ..message = eventData['message'] as String?
            ..isRead = eventData['isRead'] as bool;
          eventsToRestore.add((oldRuleId, event));
        }
      }

      final repo = sl<IAlertRepository>();
      await repo.restoreAnonymousAlertsFromCacheData(
        alertsToRestore: alertsToRestore,
        statesToRestore: statesToRestore,
        eventsToRestore: eventsToRestore,
      );

      if (kDebugMode) {
        debugPrint(
            'DataSyncService: Restored ${alertsJson.length} alerts from anonymous cache');
      }
    } catch (e, stackTrace) {
      if (kDebugMode) {
        debugPrint('DataSyncService: Error restoring alerts from cache: $e');
        debugPrint('$stackTrace');
      }
    }
  }

  /// Sync watchlist to server
  static Future<void> syncWatchlist() async {
    if (!AuthService.isSignedIn) return;

    final userId = await UserService.ensureUserId();
    final repo = sl<IWatchlistRepository>();
    final localItems = await repo.getAll();

    try {
      final uri = Uri.parse('$_baseUrl/user/watchlist');
      final payload = {
        'userId': userId,
        'symbols': localItems.map((item) => item.symbol).toList(),
      };

      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(payload),
      );

      if (response.statusCode != 200) {
        if (kDebugMode) {
          debugPrint(
              'DataSyncService: Failed to sync watchlist: ${response.statusCode} ${response.body}');
        }
      } else {
        if (kDebugMode) {
          debugPrint('DataSyncService: Watchlist synced successfully');
        }
        // Also seed widget symbols so Android widget can fetch data
        final symbols = localItems.map((item) => item.symbol).toList();
        await seedWidgetSymbols(symbols);
        // Re-apply watchlist alerts so server rules match new list (add/remove symbol)
        unawaited(refreshWatchlistAlertsForEnabledIndicators());
      }
    } catch (e, stackTrace) {
      if (kDebugMode) {
        debugPrint('DataSyncService: Error syncing watchlist: $e');
        debugPrint('$stackTrace');
      }
    }
  }

  /// Fetch watchlist from server and replace local watchlist completely
  static Future<void> fetchWatchlist() async {
    if (!AuthService.isSignedIn) return;

    final userId = await UserService.ensureUserId();

    try {
      final uri = Uri.parse('$_baseUrl/user/watchlist/$userId');
      final response = await http.get(
        uri,
        headers: {'Content-Type': 'application/json'},
      );

      if (response.statusCode != 200) {
        if (kDebugMode) {
          debugPrint(
              'DataSyncService: Failed to fetch watchlist: ${response.statusCode} ${response.body}');
        }
        return;
      }

      final decoded = jsonDecode(response.body);
      final List<dynamic>? symbols = decoded['symbols'] as List<dynamic>?;

      if (symbols == null) {
        final repo = sl<IWatchlistRepository>();
        await repo.replaceAll([]);
        // Still seed widget (with empty list) so it knows there's no data
        await seedWidgetSymbols([]);
        return;
      }

      final serverSymbols = <String>{};
      final serverSymbolsWithData = <String, Map<String, dynamic>>{};

      // Parse server symbols (use Set to avoid duplicates)
      for (final symbolData in symbols) {
        final symbol =
            symbolData is String ? symbolData : symbolData['symbol'] as String?;
        if (symbol == null || symbol.isEmpty) continue;

        // Only add if not already in set (prevent duplicates)
        if (!serverSymbols.contains(symbol)) {
          serverSymbols.add(symbol);
          if (symbolData is Map) {
            serverSymbolsWithData[symbol] =
                Map<String, dynamic>.from(symbolData);
          }
        }
      }

      final items = <WatchlistItem>[];
      for (final symbol in serverSymbols) {
        final item = WatchlistItem()..symbol = symbol;
        if (serverSymbolsWithData.containsKey(symbol) &&
            serverSymbolsWithData[symbol]!['created_at'] != null) {
          final createdAt = serverSymbolsWithData[symbol]!['created_at'];
          item.createdAt = createdAt is int
              ? createdAt
              : DateTime.now().millisecondsSinceEpoch;
        } else {
          item.createdAt = DateTime.now().millisecondsSinceEpoch;
        }
        items.add(item);
      }
      final repo = sl<IWatchlistRepository>();
      await repo.replaceAll(items);

      debugPrint('DataSyncService.fetchWatchlist: Saved ${serverSymbols.length} symbols to DB, now seeding widget...');

      // Seed widget SharedPreferences so Android widget can work immediately
      await seedWidgetSymbols(serverSymbols.toList());

      debugPrint('DataSyncService.fetchWatchlist: Watchlist fetched and widget seeded successfully (${serverSymbols.length} items)');
    } catch (e, stackTrace) {
      if (kDebugMode) {
        debugPrint('DataSyncService: Error fetching watchlist: $e');
        debugPrint('$stackTrace');
      }
    }
  }

  static const MethodChannel _widgetChannel = MethodChannel('com.indicharts.app/widget');

  /// Seed widget SharedPreferences with symbols so Android widget can fetch data.
  /// This is called after fetchWatchlist to ensure widget has symbols even on first login.
  /// Uses MethodChannel to write directly to native SharedPreferences (rsi_widget_data).
  static Future<void> seedWidgetSymbols([List<String>? symbols]) async {
    // Only Android has the widget
    if (!Platform.isAndroid) {
      debugPrint('DataSyncService.seedWidgetSymbols: Not Android, skipping');
      return;
    }
    
    try {
      List<String> symbolsToSeed;
      if (symbols != null) {
        symbolsToSeed = symbols;
      } else {
        // If no symbols passed, read from repository
        final repo = sl<IWatchlistRepository>();
        final items = await repo.getAll();
        symbolsToSeed = items.map((item) => item.symbol).toList();
      }
      
      debugPrint('DataSyncService.seedWidgetSymbols: Attempting to seed ${symbolsToSeed.length} symbols: $symbolsToSeed');
      
      if (symbolsToSeed.isEmpty) {
        debugPrint('DataSyncService.seedWidgetSymbols: No symbols to seed, skipping');
        return;
      }
      
      // Call MethodChannel to save symbols directly to native SharedPreferences
      // This triggers widget refresh so it fetches data for these symbols
      final result = await _widgetChannel.invokeMethod('seedWidgetSymbols', {
        'symbols': symbolsToSeed,
      });
      
      debugPrint('DataSyncService.seedWidgetSymbols: MethodChannel returned $result');
    } catch (e, stackTrace) {
      debugPrint('DataSyncService.seedWidgetSymbols: Error - $e');
      debugPrint('$stackTrace');
    }
  }

  /// Sync chart preferences to server
  static Future<void> syncPreferences({
    String? symbol,
    String? timeframe,
    int? rsiPeriod,
    double? lowerLevel,
    double? upperLevel,
  }) async {
    if (!AuthService.isSignedIn) {
      // In anonymous mode, save to cache
      await savePreferencesToCache(
        symbol: symbol,
        timeframe: timeframe,
        rsiPeriod: rsiPeriod,
        lowerLevel: lowerLevel,
        upperLevel: upperLevel,
      );
      return;
    }

    final userId = await UserService.ensureUserId();

    try {
      final uri = Uri.parse('$_baseUrl/user/preferences');
      final payload = <String, dynamic>{
        'userId': userId,
      };
      if (symbol != null) payload['selected_symbol'] = symbol;
      if (timeframe != null) payload['selected_timeframe'] = timeframe;
      if (rsiPeriod != null) payload['rsi_period'] = rsiPeriod;
      if (lowerLevel != null) payload['lower_level'] = lowerLevel;
      if (upperLevel != null) payload['upper_level'] = upperLevel;

      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(payload),
      );

      if (response.statusCode != 200) {
        if (kDebugMode) {
          debugPrint(
              'DataSyncService: Failed to sync preferences: ${response.statusCode} ${response.body}');
        }
      } else if (kDebugMode) {
        debugPrint('DataSyncService: Preferences synced successfully');
      }
    } catch (e, stackTrace) {
      if (kDebugMode) {
        debugPrint('DataSyncService: Error syncing preferences: $e');
        debugPrint('$stackTrace');
      }
    }
  }

  /// Fetch chart preferences from server
  static Future<Map<String, dynamic>?> fetchPreferences() async {
    if (!AuthService.isSignedIn) {
      // In anonymous mode, load from cache
      return await loadPreferencesFromCache();
    }

    final userId = await UserService.ensureUserId();

    try {
      final uri = Uri.parse('$_baseUrl/user/preferences/$userId');
      final response = await http.get(
        uri,
        headers: {'Content-Type': 'application/json'},
      );

      if (response.statusCode != 200) {
        if (kDebugMode) {
          debugPrint(
              'DataSyncService: Failed to fetch preferences: ${response.statusCode} ${response.body}');
        }
        return null;
      }

      final decoded = jsonDecode(response.body);
      
      // Helper function to safely convert int or double to double?
      double? toDouble(dynamic value) {
        if (value == null) return null;
        if (value is double) return value;
        if (value is int) return value.toDouble();
        return null;
      }
      
      return {
        'symbol': decoded['selected_symbol'] as String?,
        'timeframe': decoded['selected_timeframe'] as String?,
        'rsiPeriod': decoded['rsi_period'] as int?,
        'lowerLevel': toDouble(decoded['lower_level']),
        'upperLevel': toDouble(decoded['upper_level']),
      };
    } catch (e, stackTrace) {
      if (kDebugMode) {
        debugPrint('DataSyncService: Error fetching preferences: $e');
        debugPrint('$stackTrace');
      }
      return null;
    }
  }

  /// Server-authoritative enable/disable for watchlist alert (signed-in only).
  /// Replaces all watchlist alerts on enable; deletes them on disable. Prevents
  /// cross-device bugs (toggle off on D1 / on on D2; duplicates when both toggle on).
  static Future<({bool ok, int createdCount, int deletedCount})> putWatchlistAlert({
    required String indicator,
    required bool enabled,
    required String timeframe,
    required int period,
    int? stochDPeriod,
    required String mode,
    required double lowerLevel,
    required double upperLevel,
    required bool lowerLevelEnabled,
    required bool upperLevelEnabled,
    required int cooldownSec,
    required bool repeatable,
    required bool onClose,
  }) async {
    if (!AuthService.isSignedIn) {
      return (ok: false, createdCount: 0, deletedCount: 0);
    }

    final userId = await UserService.ensureUserId();
    try {
      final uri = Uri.parse('$_baseUrl/user/watchlist-alert');
      final payload = <String, dynamic>{
        'userId': userId,
        'indicator': indicator,
        'enabled': enabled,
        'timeframe': timeframe,
        'period': period,
        'mode': mode,
        'lowerLevel': lowerLevel,
        'upperLevel': upperLevel,
        'lowerLevelEnabled': lowerLevelEnabled,
        'upperLevelEnabled': upperLevelEnabled,
        'cooldownSec': cooldownSec,
        'repeatable': repeatable,
        'onClose': onClose,
      };
      if (stochDPeriod != null) payload['stochDPeriod'] = stochDPeriod;

      final response = await http.put(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(payload),
      );

      if (response.statusCode != 200) {
        if (kDebugMode) {
          debugPrint(
              'DataSyncService: PUT watchlist-alert failed ${response.statusCode} ${response.body}');
        }
        return (ok: false, createdCount: 0, deletedCount: 0);
      }

      final decoded = jsonDecode(response.body) as Map<String, dynamic>?;
      final createdCount = decoded?['createdCount'] as int? ?? 0;
      final deletedCount = decoded?['deletedCount'] as int? ?? 0;
      if (kDebugMode) {
        debugPrint(
            'DataSyncService: PUT watchlist-alert ok created=$createdCount deleted=$deletedCount');
      }
      return (ok: true, createdCount: createdCount, deletedCount: deletedCount);
    } catch (e, stackTrace) {
      if (kDebugMode) {
        debugPrint('DataSyncService: Error PUT watchlist-alert: $e');
        debugPrint('$stackTrace');
      }
      return (ok: false, createdCount: 0, deletedCount: 0);
    }
  }

  /// After watchlist change (add/remove symbol), re-apply watchlist alerts for each
  /// enabled indicator so server rules match the new list. Call after syncWatchlist().
  static Future<void> refreshWatchlistAlertsForEnabledIndicators() async {
    if (!AuthService.isSignedIn) return;

    final settings = await fetchWatchlistAlertSettings();
    if (settings == null || settings.isEmpty) return;

    for (final indicator in ['rsi', 'stoch', 'wpr']) {
      final s = settings[indicator] as Map<String, dynamic>?;
      if (s == null) continue;
      final enabled = s['enabled'] as bool? ?? false;
      if (!enabled) continue;

      final timeframe = s['timeframe'] as String? ?? '15m';
      final period = (s['period'] as num?)?.toInt() ?? 14;
      final stochDPeriod = (s['stochDPeriod'] as num?)?.toInt();
      final mode = s['mode'] as String? ?? 'cross';
      final lowerLevel = (s['lowerLevel'] as num?)?.toDouble() ?? 30;
      final upperLevel = (s['upperLevel'] as num?)?.toDouble() ?? 70;
      final lowerLevelEnabled = s['lowerLevelEnabled'] as bool? ?? true;
      final upperLevelEnabled = s['upperLevelEnabled'] as bool? ?? true;
      final cooldownSec = (s['cooldownSec'] as num?)?.toInt() ?? 600;
      final repeatable = s['repeatable'] as bool? ?? true;
      final onClose = s['onClose'] as bool? ?? false;

      await putWatchlistAlert(
        indicator: indicator,
        enabled: true,
        timeframe: timeframe,
        period: period,
        stochDPeriod: stochDPeriod,
        mode: mode,
        lowerLevel: lowerLevel,
        upperLevel: upperLevel,
        lowerLevelEnabled: lowerLevelEnabled,
        upperLevelEnabled: upperLevelEnabled,
        cooldownSec: cooldownSec,
        repeatable: repeatable,
        onClose: onClose,
      );
    }

    await AlertSyncService.fetchAndSyncAlerts();
  }

  /// Sync watchlist alert settings to server
  /// Stores enabled state and settings per indicator type
  static Future<void> syncWatchlistAlertSettings({
    required String indicator, // 'rsi', 'stoch', 'wpr'
    required bool enabled,
    required String timeframe,
    required int period,
    int? stochDPeriod, // Only for Stochastic
    required String mode, // 'cross', 'enter', 'exit'
    required double lowerLevel,
    required double upperLevel,
    required bool lowerLevelEnabled,
    required bool upperLevelEnabled,
    required int cooldownSec,
    required bool repeatable,
    required bool onClose,
  }) async {
    if (!AuthService.isSignedIn) {
      // In anonymous mode, settings are already in SharedPreferences
      // No need to save to cache as WatchlistScreen already handles this
      return;
    }

    final userId = await UserService.ensureUserId();

    try {
      final uri = Uri.parse('$_baseUrl/user/watchlist-alert-settings');
      final payload = <String, dynamic>{
        'userId': userId,
        'indicator': indicator,
        'enabled': enabled,
        'timeframe': timeframe,
        'period': period,
        'mode': mode,
        'lowerLevel': lowerLevel,
        'upperLevel': upperLevel,
        'lowerLevelEnabled': lowerLevelEnabled,
        'upperLevelEnabled': upperLevelEnabled,
        'cooldownSec': cooldownSec,
        'repeatable': repeatable,
        'onClose': onClose,
      };
      
      if (stochDPeriod != null) {
        payload['stochDPeriod'] = stochDPeriod;
      }

      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(payload),
      );

      if (response.statusCode != 200) {
        if (kDebugMode) {
          debugPrint(
              'DataSyncService: Failed to sync watchlist alert settings: ${response.statusCode} ${response.body}');
        }
      } else {
        if (kDebugMode) {
          debugPrint('DataSyncService: Watchlist alert settings synced successfully for $indicator');
        }
      }
    } catch (e, stackTrace) {
      if (kDebugMode) {
        debugPrint('DataSyncService: Error syncing watchlist alert settings: $e');
        debugPrint('$stackTrace');
      }
    }
  }

  /// Fetch watchlist alert settings from server
  /// Returns settings for all indicators
  static Future<Map<String, dynamic>?> fetchWatchlistAlertSettings() async {
    if (!AuthService.isSignedIn) {
      // In anonymous mode, settings are in SharedPreferences
      // Return null so WatchlistScreen uses local values
      return null;
    }

    final userId = await UserService.ensureUserId();

    try {
      final uri = Uri.parse('$_baseUrl/user/watchlist-alert-settings/$userId');
      final response = await http.get(
        uri,
        headers: {'Content-Type': 'application/json'},
      );

      if (response.statusCode != 200) {
        if (kDebugMode) {
          debugPrint(
              'DataSyncService: Failed to fetch watchlist alert settings: ${response.statusCode} ${response.body}');
        }
        return null;
      }

      final decoded = jsonDecode(response.body);
      
      if (kDebugMode) {
        debugPrint('DataSyncService: Fetched watchlist alert settings: $decoded');
      }
      
      // Server returns settings grouped by indicator:
      // {
      //   "rsi": { "enabled": true, "timeframe": "15m", "period": 14, ... },
      //   "stoch": { "enabled": false, "timeframe": "15m", "period": 6, ... },
      //   "wpr": { "enabled": false, "timeframe": "15m", "period": 14, ... }
      // }
      return decoded as Map<String, dynamic>?;
    } catch (e, stackTrace) {
      if (kDebugMode) {
        debugPrint('DataSyncService: Error fetching watchlist alert settings: $e');
        debugPrint('$stackTrace');
      }
      return null;
    }
  }
}
