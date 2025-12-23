import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:isar/isar.dart';

import '../models.dart';
import 'user_service.dart';
import 'firebase_service.dart';
import 'auth_service.dart';

/// Handles syncing alert rules with the remote Cloudflare Worker backend.
class AlertSyncService {
  static const _baseUrl = 'https://rsi-workers.vovan4ikukraine.workers.dev';

  static Future<void> syncAlert(Isar isar, AlertRule alert) async {
    final userId = await UserService.ensureUserId();
    if (kDebugMode) {
      debugPrint(
          'AlertSyncService: syncing alert ${alert.id} (remoteId=${alert.remoteId}) for userId=$userId');
    }
    try {
      if (alert.remoteId == null) {
        await _createRemoteAlert(isar, alert, userId);
      } else {
        await _updateRemoteAlert(alert, userId);
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

  static Future<void> syncPendingAlerts(Isar isar) async {
    final alerts = await isar.alertRules.where().findAll();
    for (final alert in alerts) {
      if (alert.remoteId == null) {
        await syncAlert(isar, alert);
      }
    }
  }

  /// Fetch alerts from server and sync to local database
  /// Completely replaces local alerts with server alerts (for authenticated users)
  static Future<void> fetchAndSyncAlerts(Isar isar) async {
    if (!AuthService.isSignedIn) {
      // In anonymous mode, don't fetch from server
      return;
    }

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
      final List<dynamic>? rules = decoded['rules'] as List<dynamic>?;

      // Get existing alerts by remoteId (only those with remoteId)
      final existingAlerts =
          await isar.alertRules.filter().remoteIdIsNotNull().findAll();
      final existingRemoteIds = existingAlerts
          .where((a) => a.remoteId != null)
          .map((a) => a.remoteId as int)
          .toSet();

      if (rules == null || rules.isEmpty) {
        // Server has no alerts - delete all alerts with remoteId
        await isar.writeTxn(() async {
          for (final alert in existingAlerts) {
            // Delete alert state and events first
            final states = await isar.alertStates
                .filter()
                .ruleIdEqualTo(alert.id)
                .findAll();
            for (final state in states) {
              await isar.alertStates.delete(state.id);
            }
            final events = await isar.alertEvents
                .filter()
                .ruleIdEqualTo(alert.id)
                .findAll();
            for (final event in events) {
              await isar.alertEvents.delete(event.id);
            }
            // Then delete the alert itself
            await isar.alertRules.delete(alert.id);
          }
        });
        if (kDebugMode) {
          debugPrint(
              'AlertSyncService: Server has no alerts, cleared all remote alerts');
        }
        return;
      }

      await isar.writeTxn(() async {
        // First, delete all anonymous alerts (those without remoteId) since we're loading account alerts
        final allAlerts = await isar.alertRules.where().findAll();
        for (final alert in allAlerts) {
          if (alert.remoteId == null) {
            // Delete alert state and events first
            final states = await isar.alertStates
                .filter()
                .ruleIdEqualTo(alert.id)
                .findAll();
            for (final state in states) {
              await isar.alertStates.delete(state.id);
            }
            final events = await isar.alertEvents
                .filter()
                .ruleIdEqualTo(alert.id)
                .findAll();
            for (final event in events) {
              await isar.alertEvents.delete(event.id);
            }
            // Then delete the alert itself
            await isar.alertRules.delete(alert.id);
            if (kDebugMode) {
              debugPrint(
                  'AlertSyncService: Deleted anonymous alert ${alert.id} (loading account alerts)');
            }
          }
        }

        // Now add/update alerts from server
        for (final ruleData in rules) {
          final remoteId = ruleData['id'] as int?;
          if (remoteId == null) continue;

          // Check if alert already exists
          final existing = existingAlerts.firstWhere(
            (a) => a.remoteId == remoteId,
            orElse: () => AlertRule(),
          );

          if (existing.id == Isar.autoIncrement) {
            // Create new alert
            final levelsData = ruleData['levels'] is String
                ? jsonDecode(ruleData['levels'] as String)
                : ruleData['levels'];
            final levelsList = (levelsData as List<dynamic>)
                .map((e) => (e as num).toDouble())
                .toList();

            final alert = AlertRule()
              ..remoteId = remoteId
              ..symbol = ruleData['symbol'] as String
              ..timeframe = ruleData['timeframe'] as String
              ..indicator = ruleData['indicator'] as String? ?? 'rsi'
              ..period = ruleData['period'] as int? ??
                  ruleData['rsi_period'] as int? ??
                  14
              ..indicatorParams = ruleData['indicator_params'] != null
                  ? Map<String, dynamic>.from(
                      jsonDecode(ruleData['indicator_params'] as String))
                  : null
              ..levels = levelsList
              ..mode = ruleData['mode'] as String? ?? 'cross'
              ..cooldownSec = ruleData['cooldown_sec'] as int? ?? 600
              ..active = (ruleData['active'] as int? ?? 1) == 1
              ..createdAt = ruleData['created_at'] as int? ??
                  DateTime.now().millisecondsSinceEpoch
              ..repeatable = true
              ..soundEnabled = true;

            await isar.alertRules.put(alert);
            if (kDebugMode) {
              debugPrint(
                  'AlertSyncService: Created local alert from remoteId=$remoteId');
            }
          } else {
            // Update existing alert
            final levelsData = ruleData['levels'] is String
                ? jsonDecode(ruleData['levels'] as String)
                : ruleData['levels'];
            final levelsList = (levelsData as List<dynamic>)
                .map((e) => (e as num).toDouble())
                .toList();

            existing
              ..symbol = ruleData['symbol'] as String
              ..timeframe = ruleData['timeframe'] as String
              ..indicator =
                  ruleData['indicator'] as String? ?? existing.indicator
              ..period = ruleData['period'] as int? ??
                  ruleData['rsi_period'] as int? ??
                  existing.period
              ..indicatorParams = ruleData['indicator_params'] != null
                  ? Map<String, dynamic>.from(
                      jsonDecode(ruleData['indicator_params'] as String))
                  : existing.indicatorParams
              ..levels = levelsList
              ..mode = ruleData['mode'] as String? ?? 'cross'
              ..cooldownSec = ruleData['cooldown_sec'] as int? ?? 600
              ..active = (ruleData['active'] as int? ?? 1) == 1;

            await isar.alertRules.put(existing);
            if (kDebugMode) {
              debugPrint(
                  'AlertSyncService: Updated local alert from remoteId=$remoteId');
            }
          }

          existingRemoteIds.remove(remoteId);
        }

        // Delete alerts that are no longer on server (they were deleted)
        for (final remoteId in existingRemoteIds) {
          final alert = existingAlerts.firstWhere(
            (a) => a.remoteId == remoteId,
            orElse: () => AlertRule(),
          );
          if (alert.id != Isar.autoIncrement) {
            // Delete alert state and events first
            final states = await isar.alertStates
                .filter()
                .ruleIdEqualTo(alert.id)
                .findAll();
            for (final state in states) {
              await isar.alertStates.delete(state.id);
            }
            final events = await isar.alertEvents
                .filter()
                .ruleIdEqualTo(alert.id)
                .findAll();
            for (final event in events) {
              await isar.alertEvents.delete(event.id);
            }
            // Then delete the alert itself
            await isar.alertRules.delete(alert.id);
            if (kDebugMode) {
              debugPrint(
                  'AlertSyncService: Deleted alert with remoteId=$remoteId (no longer on server)');
            }
          }
        }
      });

      if (kDebugMode) {
        debugPrint(
            'AlertSyncService: Successfully synced ${rules.length} alerts from server');
      }
    } catch (e, stackTrace) {
      if (kDebugMode) {
        debugPrint('AlertSyncService: Error fetching alerts: $e');
        debugPrint('$stackTrace');
      }
    }
  }

  static Future<void> _createRemoteAlert(
    Isar isar,
    AlertRule alert,
    String userId,
  ) async {
    final uri = Uri.parse('$_baseUrl/alerts/create');
    final payload = {
      'userId': userId,
      'deviceId': await FirebaseService.getDeviceId(),
      'symbol': alert.symbol,
      'timeframe': alert.timeframe,
      'indicator': alert.indicator,
      'period': alert.period,
      'indicatorParams': alert.indicatorParams,
      'levels': alert.levels,
      'mode': alert.mode,
      'cooldownSec': alert.cooldownSec,
    };

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
      await isar.writeTxn(() async {
        alert.remoteId = remoteId;
        await isar.alertRules.put(alert);
      });
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

  static Future<void> _updateRemoteAlert(AlertRule alert, String userId) async {
    final uri = Uri.parse('$_baseUrl/alerts/${alert.remoteId}');

    final payload = {
      'userId': userId, // Server expects 'userId', not 'user_id'
      'symbol': alert.symbol,
      'timeframe': alert.timeframe,
      'indicator': alert.indicator,
      'period': alert.period,
      'indicator_params': alert.indicatorParams != null
          ? jsonEncode(alert.indicatorParams)
          : null,
      'rsi_period': alert.period, // Keep for backward compatibility
      'levels': alert.levels, // Server expects array, not JSON string (it will stringify on server side)
      'mode': alert.mode,
      'cooldown_sec': alert.cooldownSec,
      'active': alert.active ? 1 : 0,
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
