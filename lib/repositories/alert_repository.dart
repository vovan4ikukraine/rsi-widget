import 'package:isar/isar.dart';
import '../models.dart';
import '../models/indicator_type.dart';
import '../constants/app_constants.dart';

/// Repository for AlertRule operations
/// Encapsulates database operations and provides clean API
class AlertRepository {
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
