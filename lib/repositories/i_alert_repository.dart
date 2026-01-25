import '../models.dart';
import '../models/indicator_type.dart';

/// Abstract interface for alert persistence.
/// Implementations encapsulate Isar operations.
abstract interface class IAlertRepository {
  Future<void> saveAlert(AlertRule alert);
  Future<void> saveAlerts(List<AlertRule> alerts);
  Future<void> saveAlertStates(List<AlertState> states);
  Future<void> saveAlertEvents(List<AlertEvent> events);
  Future<void> deleteAlert(int id);
  Future<void> deleteAlerts(List<int> ids);
  Future<void> deleteAlertWithRelatedData(int id);
  Future<void> deleteAlertsWithRelatedData(List<int> ids);
  Future<void> deleteAlertStateByRuleId(int ruleId);
  Future<List<AlertRule>> getAllAlerts();
  Future<AlertRule?> getAlertById(int id);
  Future<List<AlertRule>> getAlertsBySymbol(String symbol);
  Future<List<AlertRule>> getActiveAlerts();
  Future<List<AlertRule>> getActiveCustomAlerts();
  Future<List<AlertRule>> getCustomAlerts();
  Future<List<AlertEvent>> getAllAlertEvents();
  Future<List<AlertState>> getAllAlertStates();
  Future<List<AlertRule>> getWatchlistMassAlertsForIndicator(
    IndicatorType indicatorType,
  );
  Future<void> restoreAnonymousAlertsFromCacheData({
    required List<(int oldId, AlertRule rule)> alertsToRestore,
    required List<(int oldRuleId, AlertState state)> statesToRestore,
    required List<(int oldRuleId, AlertEvent event)> eventsToRestore,
  });
  Future<void> replaceAlertsWithServerSnapshot(
    List<Map<String, dynamic>> rules,
  );
}
