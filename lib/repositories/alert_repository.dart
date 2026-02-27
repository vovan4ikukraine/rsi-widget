import 'dart:convert';

import 'package:isar_db/isar_db.dart';
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
  @override
  Future<void> saveAlert(AlertRule alert) async {
    isar.write((i) => i.alertRules.put(alert));
  }

  /// Save multiple alert states in a single transaction
  @override
  Future<void> saveAlertStates(List<AlertState> states) async {
    if (states.isEmpty) return;
    await isar.write((i) async {
      for (final state in states) {
        i.alertStates.put(state);
      }
    });
  }

  /// Save multiple alerts in a single transaction
  @override
  Future<void> saveAlerts(List<AlertRule> alerts) async {
    if (alerts.isEmpty) return;
    await isar.write((i) async {
      for (final alert in alerts) {
        i.alertRules.put(alert);
      }
    });
  }

  /// Delete an alert by ID
  @override
  Future<void> deleteAlert(int id) async {
    isar.write((i) => i.alertRules.delete(id));
  }

  /// Delete multiple alerts in a single transaction
  @override
  Future<void> deleteAlerts(List<int> ids) async {
    if (ids.isEmpty) return;
    await isar.write((i) async {
      for (final id in ids) {
        i.alertRules.delete(id);
      }
    });
  }

  /// Delete an alert with all related data (states and events) in a single transaction
  @override
  Future<void> deleteAlertWithRelatedData(int id) async {
    await isar.write((i) async {
      // Delete alert state
      try {
        final alertState = i.alertStates
            .where()
            .ruleIdEqualTo(id)
            .findFirst();
        if (alertState != null && alertState.id > 0) {
          i.alertStates.delete(alertState.id);
        }
      } catch (e) {
        // Ignore errors - state may not exist
      }

      // Delete alert events
      try {
        final events = i.alertEvents
            .where()
            .ruleIdEqualTo(id)
            .findAll();
        for (final event in events) {
          if (event.id > 0) {
            i.alertEvents.delete(event.id);
          }
        }
      } catch (e) {
        // Ignore errors - events may not exist
      }

      // Delete alert rule
      i.alertRules.delete(id);
    });
  }

  /// Delete multiple alerts with all related data (states and events) in a single transaction
  @override
  Future<void> deleteAlertsWithRelatedData(List<int> ids) async {
    await isar.write((i) async {
      for (final id in ids) {
        if (id <= 0) continue;

        // Delete alert state
        try {
          final alertState = i.alertStates
              .where()
              .ruleIdEqualTo(id)
              .findFirst();
        if (alertState != null && alertState.id > 0) {
          i.alertStates.delete(alertState.id);
        }
        } catch (e) {
          // Ignore errors - state may not exist
        }

        // Delete alert events
        try {
          final events = i.alertEvents
              .where()
              .ruleIdEqualTo(id)
              .findAll();
          for (final event in events) {
          if (event.id > 0) {
            i.alertEvents.delete(event.id);
          }
          }
        } catch (e) {
          // Ignore errors - events may not exist
        }

        // Delete alert rule
        i.alertRules.delete(id);
      }
    });
  }

  /// Delete alert state by rule ID
  @override
  Future<void> deleteAlertStateByRuleId(int ruleId) async {
    await isar.write((i) async {
      try {
        final alertState = i.alertStates
            .where()
            .ruleIdEqualTo(ruleId)
            .findFirst();
        if (alertState != null && alertState.id > 0) {
          i.alertStates.delete(alertState.id);
        }
      } catch (e) {
        // Ignore errors - state may not exist
      }
    });
  }

  /// Delete alert events by rule ID
  Future<void> deleteAlertEventsByRuleId(int ruleId) async {
    await isar.write((i) async {
      try {
        final events = i.alertEvents
            .where()
            .ruleIdEqualTo(ruleId)
            .findAll();
        for (final event in events) {
          if (event.id > 0) {
            i.alertEvents.delete(event.id);
          }
        }
      } catch (e) {
        // Ignore errors - events may not exist
      }
    });
  }

  /// Get all alerts
  @override
  Future<List<AlertRule>> getAllAlerts() async {
    return isar.alertRules.where().findAll();
  }

  /// Get alert by ID
  @override
  Future<AlertRule?> getAlertById(int id) async {
    return isar.alertRules.get(id);
  }

  /// Get alerts by symbol
  @override
  Future<List<AlertRule>> getAlertsBySymbol(String symbol) async {
    return isar.alertRules
        .where()
        .symbolEqualTo(symbol)
        .findAll();
  }

  /// Get active alerts
  @override
  Future<List<AlertRule>> getActiveAlerts() async {
    return isar.alertRules
        .where()
        .activeEqualTo(true)
        .findAll();
  }

  /// Get active alerts excluding watchlist alerts (for home chart)
  @override
  Future<List<AlertRule>> getActiveCustomAlerts() async {
    final active = await getActiveAlerts();
    return active.where((a) {
      final desc = a.description;
      if (desc == null) return true;
      return !desc.toUpperCase().contains(AppConstants.watchlistAlertPrefix);
    }).toList();
  }

  /// Get all alert events
  @override
  Future<List<AlertEvent>> getAllAlertEvents() async {
    return isar.alertEvents.where().findAll();
  }

  /// Get all alert states
  @override
  Future<List<AlertState>> getAllAlertStates() async {
    return isar.alertStates.where().findAll();
  }

  /// Save multiple alert events in a single transaction
  @override
  Future<void> saveAlertEvents(List<AlertEvent> events) async {
    if (events.isEmpty) return;
    await isar.write((i) async {
      for (final event in events) {
        i.alertEvents.put(event);
      }
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
  @override
  Future<void> restoreAnonymousAlertsFromCacheData({
    required List<(int oldId, AlertRule rule)> alertsToRestore,
    required List<(int oldRuleId, AlertState state)> statesToRestore,
    required List<(int oldRuleId, AlertEvent event)> eventsToRestore,
  }) async {
    final idMap = <int, int>{};
    await isar.write((i) async {
      await _deleteAnonymousInTxn(i);
      for (final r in alertsToRestore) {
        final oldId = r.$1;
        final rule = r.$2;
        i.alertRules.put(rule);
        idMap[oldId] = rule.id;
      }
      for (final s in statesToRestore) {
        final oldRuleId = s.$1;
        final state = s.$2;
        final newRuleId = idMap[oldRuleId];
        if (newRuleId != null) {
          state.ruleId = newRuleId;
          i.alertStates.put(state);
        }
      }
      for (final e in eventsToRestore) {
        final oldRuleId = e.$1;
        final event = e.$2;
        final newRuleId = idMap[oldRuleId];
        if (newRuleId != null) {
          event.ruleId = newRuleId;
          i.alertEvents.put(event);
        }
      }
    });
  }

  /// Get alerts with remoteId set (for fetch-and-sync)
  Future<List<AlertRule>> getAlertsWithRemoteId() async {
    return isar.alertRules.where().remoteIdIsNotNull().findAll();
  }

  /// Replace local alerts with server snapshot (fetch-and-sync logic).
  /// Deletes anonymous alerts, then adds/updates from [rules], removes locals not on server.
  @override
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

    await isar.write((i) async {
      await _deleteAnonymousInTxn(i);
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
          i.alertRules.put(alert);
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
          i.alertRules.put(ex);
        }
        existingRemoteIds.remove(remoteId);
      }
      for (final remoteId in existingRemoteIds) {
        final toDelete =
            existingAlerts.where((a) => a.remoteId == remoteId).toList();
        if (toDelete.isNotEmpty) {
          await _deleteAlertWithRelatedDataInTxn(i, toDelete.first.id);
        }
      }
    });
  }

  /// Must be called inside an active write callback with the same isar instance.
  Future<void> _deleteAlertWithRelatedDataInTxn(Isar i, int id) async {
    try {
      final states =
          i.alertStates.where().ruleIdEqualTo(id).findAll();
      for (final s in states) {
        i.alertStates.delete(s.id);
      }
    } catch (_) {}
    try {
      final events =
          i.alertEvents.where().ruleIdEqualTo(id).findAll();
      for (final e in events) {
        i.alertEvents.delete(e.id);
      }
    } catch (_) {}
    i.alertRules.delete(id);
  }

  Future<void> _deleteAnonymousInTxn(Isar i) async {
    final all = i.alertRules.where().findAll();
    for (final a in all) {
      if (a.remoteId == null) {
        final states =
            i.alertStates.where().ruleIdEqualTo(a.id).findAll();
        for (final s in states) {
          i.alertStates.delete(s.id);
        }
        final events =
            i.alertEvents.where().ruleIdEqualTo(a.id).findAll();
        for (final e in events) {
          i.alertEvents.delete(e.id);
        }
        i.alertRules.delete(a.id);
      }
    }
  }

  /// Get alerts excluding watchlist alerts
  @override
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
  @override
  Future<List<AlertRule>> getWatchlistMassAlertsForIndicator(
    IndicatorType indicatorType,
  ) async {
    final allAlerts = await getAllAlerts();
    final indicatorName = indicatorType.toJson();
    final watchlistAlertDescription =
        '${AppConstants.watchlistAlertPrefix} Mass alert for $indicatorName';
    const williamsAltDescription =
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
