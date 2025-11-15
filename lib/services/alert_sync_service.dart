import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:isar/isar.dart';

import '../models.dart';
import 'user_service.dart';
import 'firebase_service.dart';

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
      final uri = Uri.parse('$_baseUrl/alerts/${alert.remoteId}').replace(
        queryParameters: hardDelete ? {'hard': 'true'} : {},
      );
      final response = await http.delete(
        uri,
        headers: {'Content-Type': 'application/json'},
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
      'rsiPeriod': alert.rsiPeriod,
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
      'symbol': alert.symbol,
      'timeframe': alert.timeframe,
      'rsi_period': alert.rsiPeriod,
      'levels': jsonEncode(alert.levels),
      'mode': alert.mode,
      'cooldown_sec': alert.cooldownSec,
      'active': alert.active ? 1 : 0,
      'user_id': userId,
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
