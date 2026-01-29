import 'dart:convert';

import 'package:isar/isar.dart';
import '../models.dart';
import '../models/indicator_type.dart';
import '../constants/app_constants.dart';
import 'i_alert_repository.dart';

/// Repository for AlertRule operations.
/// Encapsulates database operations and provides a clean API.
class AlertRepository implements IAlertRepository {
  final Isar isar;

  AlertRepository(this.isar);

  /// Save or update an alert
  Future<void> saveAlert(AlertRule alert) async {
    await isar.writeTxn(() => isar.alertRules.put(alert));
  }

  /// Save multiple alert states in a single transaction
  Future<void> saveAlertStates(List<AlertState> states) async {
    if (states.isEmpty) return;
    await isar.writeTxn(() async {
      for (final state in states) {
        await isar.alertStates.put(state);
      }
      return Future<void>.value();
    });
  }

  /// Save multiple alerts in a single transaction
  Future<void> saveAlerts(List<AlertRule> alerts) async {
    if (alerts.isEmpty) return;
    await isar.writeTxn(() async {
      for (final alert in alerts) {
        await isar.alertRules.put(alert);
      }
      return Future<void>.value();
    });
  }

  /// Delete an alert by ID
  Future<void> deleteAlert(int id) async {
    await isar.writeTxn(() => isar.alertRules.delete(id));
  }

  /// Delete multiple alerts in a single transaction
  Future<void> deleteAlerts(List<int> ids) async {
    if (ids.isEmpty) return;
    await isar.writeTxn(() async {
      for (final id in ids) {
        await isar.alertRules.delete(id);
      }
      return Future<void>.value();
    });
  }

  /// Delete an alert with all related data (states and events) in a single transaction
  Future<void> deleteAlertWithRelatedData(int id) async {
    await isar.writeTxn(() async {
      // Delete alert state
      try {
        final alertState = await isar.alertStates
            .filter()
            .ruleIdEqualTo(id)
            .findFirst();
        if (alertState != null && alertState.id > 0) {
          await isar.alertStates.delete(alertState.id);
        }
      } catch (e) {
        // Ignore errors - state may not exist
      }

      // Delete alert events
      try {
        final events = await isar.alertEvents
            .filter()
            .ruleIdEqualTo(id)
            .findAll();
        for (final event in events) {
          if (event.id > 0) {
            await isar.alertEvents.delete(event.id);
          }
        }
      } catch (e) {
        // Ignore errors - events may not exist
      }

      // Delete alert rule
      await isar.alertRules.delete(id);
    });
  }

  /// Delete multiple alerts with all related data (states and events) in a single transaction
  Future<void> deleteAlertsWithRelatedData(List<int> ids) async {
    await isar.writeTxn(() async {
      for (final id in ids) {
        if (id <= 0) continue;

        // Delete alert state
        try {
          final alertState = await isar.alertStates
              .filter()
              .ruleIdEqualTo(id)
              .findFirst();
          if (alertState != null && alertState.id > 0) {
            await isar.alertStates.delete(alertState.id);
          }
        } catch (e) {
          // Ignore errors - state may not exist
        }

        // Delete alert events
        try {
          final events = await isar.alertEvents
              .filter()
              .ruleIdEqualTo(id)
              .findAll();
          for (final event in events) {
            if (event.id > 0) {
              await isar.alertEvents.delete(event.id);
            }
          }
        } catch (e) {
          // Ignore errors - events may not exist
        }

        // Delete alert rule
        await isar.alertRules.delete(id);
      }
    });
  }

  /// Delete alert state by rule ID
  Future<void> deleteAlertStateByRuleId(int ruleId) async {
    await isar.writeTxn(() async {
      try {
        final alertState = await isar.alertStates
            .filter()
            .ruleIdEqualTo(ruleId)
            .findFirst();
        if (alertState != null && alertState.id > 0) {
          await isar.alertStates.delete(alertState.id);
        }
      } catch (e) {
        // Ignore errors - state may not exist
      }
    });
  }

  /// Delete alert events by rule ID
  Future<void> deleteAlertEventsByRuleId(int ruleId) async {
    await isar.writeTxn(() async {
      try {
        final events = await isar.alertEvents
            .filter()
            .ruleIdEqualTo(ruleId)
            .findAll();
        for (final event in events) {
          if (event.id > 0) {
            await isar.alertEvents.delete(event.id);
          }
        }
      } catch (e) {
        // Ignore errors - events may not exist
      }
    });
  }

  /// Get all alerts
  Future<List<AlertRule>> getAllAlerts() async {
    return await isar.alertRules.where().findAll();
  }

  /// Get alert by ID
  Future<AlertRule?> getAlertById(int id) async {
    return await isar.alertRules.get(id);
  }

  /// Get alerts by symbol
  Future<List<AlertRule>> getAlertsBySymbol(String symbol) async {
    return await isar.alertRules
        .filter()
        .symbolEqualTo(symbol)
        .findAll();
  }

  /// Get active alerts
  Future<List<AlertRule>> getActiveAlerts() async {
    return await isar.alertRules
        .filter()
        .activeEqualTo(true)
        .findAll();
  }

  /// Get active alerts excluding watchlist alerts (for home chart)
  Future<List<AlertRule>> getActiveCustomAlerts() async {
    final active = await getActiveAlerts();
    return active.where((a) {
      final desc = a.description;
      if (desc == null) return true;
      return !desc.toUpperCase().contains(AppConstants.watchlistAlertPrefix);
    }).toList();
  }

  /// Get all alert events
  Future<List<AlertEvent>> getAllAlertEvents() async {
    return await isar.alertEvents.where().findAll();
  }

  /// Get all alert states
  Future<List<AlertState>> getAllAlertStates() async {
    return await isar.alertStates.where().findAll();
  }

  /// Save multiple alert events in a single transaction
  Future<void> saveAlertEvents(List<AlertEvent> events) async {
    if (events.isEmpty) return;
    await isar.writeTxn(() async {
      for (final event in events) {
        await isar.alertEvents.put(event);
      }
      return Future<void>.value();
    });
  }

  /// Delete all anonymous alerts (remoteId == null) with related states and events
  Future<void> deleteAnonymousAlertsWithRelatedData() async {
    final all = await getAllAlerts();
    final ids = all.where((a) => a.remoteId == null).map((a) => a.id).toList();
    await deleteAlertsWithRelatedData(ids);
  }

  /// Restore anonymous alerts from cache data in a single transaction.
  /// Deletes anonymous alerts, then puts [alertsToRestore], [statesToRestore], [eventsToRestore].
  /// States/events use placeholder ruleId; repo overwrites with new ruleId from idMap before put.
  Future<void> restoreAnonymousAlertsFromCacheData({
    required List<(int oldId, AlertRule rule)> alertsToRestore,
    required List<(int oldRuleId, AlertState state)> statesToRestore,
    required List<(int oldRuleId, AlertEvent event)> eventsToRestore,
  }) async {
    final idMap = <int, int>{};
    await isar.writeTxn(() async {
      await _deleteAnonymousInTxn();
      for (final r in alertsToRestore) {
        final oldId = r.$1;
        final rule = r.$2;
        await isar.alertRules.put(rule);
        idMap[oldId] = rule.id;
      }
      for (final s in statesToRestore) {
        final oldRuleId = s.$1;
        final state = s.$2;
        final newRuleId = idMap[oldRuleId];
        if (newRuleId != null) {
          state.ruleId = newRuleId;
          await isar.alertStates.put(state);
        }
      }
      for (final e in eventsToRestore) {
        final oldRuleId = e.$1;
        final event = e.$2;
        final newRuleId = idMap[oldRuleId];
        if (newRuleId != null) {
          event.ruleId = newRuleId;
          await isar.alertEvents.put(event);
        }
      }
      return Future<void>.value();
    });
  }

  /// Get alerts with remoteId set (for fetch-and-sync)
  Future<List<AlertRule>> getAlertsWithRemoteId() async {
    return await isar.alertRules.filter().remoteIdIsNotNull().findAll();
  }

  /// Replace local alerts with server snapshot (fetch-and-sync logic).
  /// Deletes anonymous alerts, then adds/updates from [rules], removes locals not on server.
  Future<void> replaceAlertsWithServerSnapshot(
    List<Map<String, dynamic>> rules,
  ) async {
    final existingAlerts = await getAlertsWithRemoteId();
    final existingRemoteIds = existingAlerts
        .where((a) => a.remoteId != null)
        .map((a) => a.remoteId as int)
        .toSet();

    if (rules.isEmpty) {
      await deleteAlertsWithRelatedData(
        existingAlerts.map((a) => a.id).toList(),
      );
      return;
    }

    await isar.writeTxn(() async {
      await _deleteAnonymousInTxn();
      for (final ruleData in rules) {
        final remoteId = ruleData['id'] as int?;
        if (remoteId == null) continue;
        final matches =
            existingAlerts.where((a) => a.remoteId == remoteId).toList();
        final ex = matches.isEmpty ? null : matches.first;
        if (ex == null) {
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
                    jsonDecode(ruleData['indicator_params'] as String) as Map)
                : null
            ..levels = levelsList
            ..mode = ruleData['mode'] as String? ?? 'cross'
            ..cooldownSec = ruleData['cooldown_sec'] as int? ?? 600
            ..active = (ruleData['active'] as int? ?? 1) == 1
            ..createdAt = ruleData['created_at'] as int? ??
                DateTime.now().millisecondsSinceEpoch
            ..description = ruleData['description'] as String?
            ..alertOnClose = (ruleData['alert_on_close'] as int? ?? 0) == 1
            ..repeatable = true
            ..soundEnabled = true
            ..source = ruleData['source'] as String? ?? 'custom';
          await isar.alertRules.put(alert);
        } else {
          final levelsData = ruleData['levels'] is String
              ? jsonDecode(ruleData['levels'] as String)
              : ruleData['levels'];
          final levelsList = (levelsData as List<dynamic>)
              .map((e) => (e as num).toDouble())
              .toList();
          ex
            ..symbol = ruleData['symbol'] as String
            ..timeframe = ruleData['timeframe'] as String
            ..indicator =
                ruleData['indicator'] as String? ?? ex.indicator
            ..period = ruleData['period'] as int? ??
                ruleData['rsi_period'] as int? ??
                ex.period
            ..indicatorParams = ruleData['indicator_params'] != null
                ? Map<String, dynamic>.from(
                    jsonDecode(ruleData['indicator_params'] as String) as Map)
                : ex.indicatorParams
            ..levels = levelsList
            ..mode = ruleData['mode'] as String? ?? 'cross'
            ..cooldownSec = ruleData['cooldown_sec'] as int? ?? 600
            ..active = (ruleData['active'] as int? ?? 1) == 1
            ..description =
                ruleData['description'] as String? ?? ex.description
            ..alertOnClose = ruleData['alert_on_close'] != null
                ? (ruleData['alert_on_close'] as int? ?? 0) == 1
                : ex.alertOnClose
            ..source = ruleData['source'] as String? ?? ex.source;
          await isar.alertRules.put(ex);
        }
        existingRemoteIds.remove(remoteId);
      }
      for (final remoteId in existingRemoteIds) {
        final toDelete =
            existingAlerts.where((a) => a.remoteId == remoteId).toList();
        if (toDelete.isNotEmpty) {
          await _deleteAlertWithRelatedDataInTxn(toDelete.first.id);
        }
      }
      return Future<void>.value();
    });
  }

  /// Must be called inside an active writeTxn.
  Future<void> _deleteAlertWithRelatedDataInTxn(int id) async {
    try {
      final states =
          await isar.alertStates.filter().ruleIdEqualTo(id).findAll();
      for (final s in states) await isar.alertStates.delete(s.id);
    } catch (_) {}
    try {
      final events =
          await isar.alertEvents.filter().ruleIdEqualTo(id).findAll();
      for (final e in events) await isar.alertEvents.delete(e.id);
    } catch (_) {}
    await isar.alertRules.delete(id);
  }

  Future<void> _deleteAnonymousInTxn() async {
    final all = await isar.alertRules.where().findAll();
    for (final a in all) {
      if (a.remoteId == null) {
        final states =
            await isar.alertStates.filter().ruleIdEqualTo(a.id).findAll();
        for (final s in states) await isar.alertStates.delete(s.id);
        final events =
            await isar.alertEvents.filter().ruleIdEqualTo(a.id).findAll();
        for (final e in events) await isar.alertEvents.delete(e.id);
        await isar.alertRules.delete(a.id);
      }
    }
  }

  /// Get alerts excluding watchlist alerts
  Future<List<AlertRule>> getCustomAlerts() async {
    final allAlerts = await getAllAlerts();
    return allAlerts.where((a) {
      final desc = a.description;
      if (desc == null) return true;
      return !desc.toUpperCase().contains('WATCHLIST:');
    }).toList();
  }

  /// Get watchlist alerts
  Future<List<AlertRule>> getWatchlistAlerts() async {
    final allAlerts = await getAllAlerts();
    return allAlerts.where((a) {
      final desc = a.description;
      if (desc == null) return false;
      return desc.toUpperCase().contains('WATCHLIST:');
    }).toList();
  }

  /// Get watchlist mass alerts for a specific indicator (e.g. "WATCHLIST: Mass alert for rsi").
  /// Handles WPR/williams alternate description from server.
  Future<List<AlertRule>> getWatchlistMassAlertsForIndicator(
    IndicatorType indicatorType,
  ) async {
    final allAlerts = await getAllAlerts();
    final indicatorName = indicatorType.toJson();
    final watchlistAlertDescription =
        '${AppConstants.watchlistAlertPrefix} Mass alert for $indicatorName';
    final williamsAltDescription =
        '${AppConstants.watchlistAlertPrefix} Mass alert for williams';

    return allAlerts.where((a) {
      if (a.description == null) return false;
      if (a.description != watchlistAlertDescription) {
        if (indicatorType == IndicatorType.williams &&
            a.description != williamsAltDescription) {
          return false;
        } else if (indicatorType != IndicatorType.williams) {
          return false;
        }
      }
      try {
        final alertIndicatorType = IndicatorType.fromJson(a.indicator);
        return alertIndicatorType == indicatorType;
      } catch (_) {
        return false;
      }
    }).toList();
  }

  /// Check if alert exists for symbol with same parameters
  Future<bool> hasMatchingAlert({
    required String symbol,
    required String timeframe,
    required String indicator,
    required int period,
    required List<double> levels,
    Map<String, dynamic>? indicatorParams,
  }) async {
    final alerts = await getAlertsBySymbol(symbol);
    return alerts.any((a) =>
        a.timeframe == timeframe &&
        a.indicator == indicator &&
        a.period == period &&
        _areLevelsEqual(a.levels, levels) &&
        _areIndicatorParamsEqual(a.indicatorParams, indicatorParams));
  }

  /// Helper: Compare levels
  bool _areLevelsEqual(List<double> a, List<double> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if ((a[i] - b[i]).abs() > 0.001) return false;
    }
    return true;
  }

  /// Helper: Compare indicator params
  bool _areIndicatorParamsEqual(
    Map<String, dynamic>? a,
    Map<String, dynamic>? b,
  ) {
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (a[key] != b[key]) return false;
    }
    return true;
  }
}
