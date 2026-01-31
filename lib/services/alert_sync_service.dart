import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import '../di/app_container.dart';
import '../models.dart';
import '../models/indicator_type.dart';
import '../repositories/i_alert_repository.dart';
import 'user_service.dart';
import 'firebase_service.dart';
import 'auth_service.dart';

/// Handles syncing alert rules with the remote Cloudflare Worker backend.
class AlertSyncService {
  static String get _baseUrl => AppConfig.apiBaseUrl;

  static Future<void> syncAlert(
    AlertRule alert, {
    bool? lowerLevelEnabled,
    bool? upperLevelEnabled,
    double? lowerLevelValue,
    double? upperLevelValue,
  }) async {
    final userId = await UserService.ensureUserId();
    if (kDebugMode) {
      debugPrint(
          'AlertSyncService: syncing alert ${alert.id} (remoteId=${alert.remoteId}) for userId=$userId');
    }
    try {
      if (alert.remoteId == null) {
        await _createRemoteAlert(alert, userId,
          lowerLevelEnabled: lowerLevelEnabled,
          upperLevelEnabled: upperLevelEnabled,
          lowerLevelValue: lowerLevelValue,
          upperLevelValue: upperLevelValue,
        );
      } else {
        await _updateRemoteAlert(alert, userId,
          lowerLevelEnabled: lowerLevelEnabled,
          upperLevelEnabled: upperLevelEnabled,
          lowerLevelValue: lowerLevelValue,
          upperLevelValue: upperLevelValue,
        );
      }
    } catch (e, stackTrace) {
      if (kDebugMode) {
        debugPrint('AlertSyncService: Failed to sync alert ${alert.id}: $e');
        debugPrint('$stackTrace');
      }
    }
  }

  static Future<void> deleteAlert(AlertRule alert,
      {bool hardDelete = true}) async {
    if (alert.remoteId == null) return;

    try {
      final userId = await UserService.ensureUserId();
      final uri = Uri.parse('$_baseUrl/alerts/${alert.remoteId}').replace(
        queryParameters: hardDelete ? {'hard': 'true'} : {},
      );
      final response = await http.delete(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'userId': userId}),
      );
      if (response.statusCode >= 400 && kDebugMode) {
        debugPrint(
            'AlertSyncService: Failed to delete remote alert ${alert.remoteId}: '
            '${response.statusCode} ${response.body}');
      } else if (kDebugMode) {
        debugPrint(
            'AlertSyncService: Alert ${alert.remoteId} ${hardDelete ? "hard" : "soft"} deleted successfully');
      }
    } catch (e, stackTrace) {
      if (kDebugMode) {
        debugPrint(
            'AlertSyncService: Error deleting remote alert ${alert.remoteId}: $e');
        debugPrint('$stackTrace');
      }
    }
  }

  static Future<void> syncPendingAlerts() async {
    final repo = sl<IAlertRepository>();
    final alerts = await repo.getAllAlerts();
    for (final alert in alerts) {
      if (alert.remoteId == null) {
        await syncAlert(alert);
      }
    }
  }

  /// Fetch alerts from server and sync to local database
  /// Completely replaces local alerts with server alerts (for authenticated users)
  static Future<void> fetchAndSyncAlerts() async {
    if (!AuthService.isSignedIn) return;

    final userId = await UserService.ensureUserId();
    if (kDebugMode) {
      debugPrint('AlertSyncService: Fetching alerts for userId=$userId');
    }

    try {
      final uri = Uri.parse('$_baseUrl/alerts/$userId');
      final response = await http.get(
        uri,
        headers: {'Content-Type': 'application/json'},
      );

      if (response.statusCode != 200) {
        if (kDebugMode) {
          debugPrint(
              'AlertSyncService: Failed to fetch alerts: ${response.statusCode} ${response.body}');
        }
        return;
      }

      final decoded = jsonDecode(response.body);
      final raw = decoded['rules'] as List<dynamic>?;
      final rules = (raw ?? <dynamic>[])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

      final repo = sl<IAlertRepository>();
      await repo.replaceAlertsWithServerSnapshot(rules);

      if (kDebugMode) {
        debugPrint(
            'AlertSyncService: Successfully synced ${rules.length} alerts from server');
      }
    } catch (e, stackTrace) {
      if (kDebugMode) {
        debugPrint('AlertSyncService: Error fetching/syncing alerts: $e');
        debugPrint('$stackTrace');
      }
    }
  }

  static Future<void> _createRemoteAlert(
    AlertRule alert,
    String userId, {
    bool? lowerLevelEnabled,
    bool? upperLevelEnabled,
    double? lowerLevelValue,
    double? upperLevelValue,
  }) async {
    final uri = Uri.parse('$_baseUrl/alerts/create');
    // Convert indicator to server format (williams -> williams, not wpr)
    final indicatorType = IndicatorType.fromJson(alert.indicator);
    final serverIndicator = indicatorType.toServerJson();
    
    // Convert levels array to always have 2 elements [lower, upper] with null for disabled
    // Use provided enabled state if available, otherwise try to reconstruct from stored levels
    final levelsForServer = <double?>[];
    if (lowerLevelEnabled != null && upperLevelEnabled != null) {
      // We have full information about enabled levels
      final lower = (lowerLevelEnabled && lowerLevelValue != null && lowerLevelValue.isFinite) ? lowerLevelValue : null;
      final upper = (upperLevelEnabled && upperLevelValue != null && upperLevelValue.isFinite) ? upperLevelValue : null;
      levelsForServer.add(lower);
      levelsForServer.add(upper);
    } else {
      // Fallback: try to reconstruct from stored levels array
      if (alert.levels.isEmpty) {
        levelsForServer.addAll([null, null]);
      } else if (alert.levels.length == 1) {
        // Single level - can't determine if it's lower or upper, assume lower
        levelsForServer.addAll([alert.levels[0], null]);
      } else {
        // Two levels - assume first is lower, second is upper
        levelsForServer.addAll([alert.levels[0], alert.levels[1]]);
      }
    }
    
    final payload = {
      'userId': userId,
      'deviceId': await FirebaseService.getDeviceId(),
      'symbol': alert.symbol,
      'timeframe': alert.timeframe,
      'indicator': serverIndicator,
      'period': alert.period,
      'indicatorParams': alert.indicatorParams,
      'levels': levelsForServer,
      'mode': alert.mode,
      'cooldownSec': alert.cooldownSec,
      if (alert.description != null && alert.description!.isNotEmpty) 'description': alert.description,
      'alertOnClose': alert.alertOnClose,
      'source': alert.source, // 'watchlist' or 'custom' - for notification differentiation
    };

    if (kDebugMode) {
      debugPrint('AlertSyncService: Creating alert ${alert.id} with indicator=${alert.indicator} -> serverIndicator=$serverIndicator, levels=${alert.levels}');
      debugPrint('AlertSyncService: levelsForServer=$levelsForServer');
      debugPrint('AlertSyncService: lowerLevelEnabled=$lowerLevelEnabled, upperLevelEnabled=$upperLevelEnabled');
      debugPrint('AlertSyncService: lowerLevelValue=$lowerLevelValue, upperLevelValue=$upperLevelValue');
      debugPrint('AlertSyncService: Payload indicator=${payload['indicator']}, levels=${payload['levels']}');
      debugPrint('AlertSyncService: JSON payload levels=${jsonEncode(levelsForServer)}');
    }

    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(payload),
    );

    if (response.statusCode != 200) {
      if (kDebugMode) {
        debugPrint(
            'AlertSyncService: create failed ${response.statusCode}: ${response.body}');
      }
      throw Exception('Create failed: ${response.statusCode} ${response.body}');
    }

    final decoded = jsonDecode(response.body);
    final dynamic remoteIdValue = decoded['id'];
    final int? remoteId = remoteIdValue is int
        ? remoteIdValue
        : (remoteIdValue is String ? int.tryParse(remoteIdValue) : null);
    if (remoteId != null) {
      alert.remoteId = remoteId;
      final repo = sl<IAlertRepository>();
      await repo.saveAlert(alert);
      if (kDebugMode) {
        debugPrint(
            'AlertSyncService: alert ${alert.id} synced with remoteId=$remoteId');
      }
    } else {
      if (kDebugMode) {
        debugPrint(
            'AlertSyncService: create response missing id for alert ${alert.id}: ${response.body}');
      }
    }
  }

  static Future<void> _updateRemoteAlert(
    AlertRule alert, 
    String userId, {
    bool? lowerLevelEnabled,
    bool? upperLevelEnabled,
    double? lowerLevelValue,
    double? upperLevelValue,
  }) async {
    final uri = Uri.parse('$_baseUrl/alerts/${alert.remoteId}');

    // Convert indicator to server format (williams -> williams, not wpr)
    final indicatorType = IndicatorType.fromJson(alert.indicator);
    final serverIndicator = indicatorType.toServerJson();

    // Convert levels array to always have 2 elements [lower, upper] with null for disabled
    final levelsForServer = <double?>[];
    if (lowerLevelEnabled != null && upperLevelEnabled != null) {
      // We have full information about enabled levels
      levelsForServer.add(lowerLevelEnabled && lowerLevelValue != null ? lowerLevelValue : null);
      levelsForServer.add(upperLevelEnabled && upperLevelValue != null ? upperLevelValue : null);
    } else {
      // Fallback: try to reconstruct from stored levels array
      if (alert.levels.isEmpty) {
        levelsForServer.addAll([null, null]);
      } else if (alert.levels.length == 1) {
        // Single level - can't determine if it's lower or upper, assume lower
        levelsForServer.addAll([alert.levels[0], null]);
      } else {
        // Two levels - assume first is lower, second is upper
        levelsForServer.addAll([alert.levels[0], alert.levels[1]]);
      }
    }
    
    final payload = {
      'userId': userId, // Server expects 'userId', not 'user_id'
      'symbol': alert.symbol,
      'timeframe': alert.timeframe,
      'indicator': serverIndicator,
      'period': alert.period,
      'indicator_params': alert.indicatorParams != null
          ? jsonEncode(alert.indicatorParams)
          : null,
      'rsi_period': alert.period, // Keep for backward compatibility
      'levels': levelsForServer, // Always send array with 2 elements [lower, upper] with null for disabled
      'mode': alert.mode,
      'cooldown_sec': alert.cooldownSec,
      'active': alert.active ? 1 : 0,
      'alert_on_close': alert.alertOnClose,
      'source': alert.source, // 'watchlist' or 'custom' - for notification differentiation
    };

    final response = await http.put(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(payload),
    );

    if (response.statusCode >= 400) {
      if (kDebugMode) {
        debugPrint(
            'AlertSyncService: update failed for alert ${alert.id} (${alert.remoteId}) '
            'with ${response.statusCode}: ${response.body}');
      }
      throw Exception('Update failed: ${response.statusCode} ${response.body}');
    }
    if (kDebugMode) {
      debugPrint(
          'AlertSyncService: alert ${alert.id} (${alert.remoteId}) updated successfully');
    }
  }
}
