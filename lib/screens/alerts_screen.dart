import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:isar/isar.dart';
import '../models.dart';
import '../models/indicator_type.dart';
import 'create_alert_screen.dart';
import '../localization/app_localizations.dart';
import '../services/alert_sync_service.dart';
import '../services/error_service.dart';
import '../state/app_state.dart';
import '../widgets/indicator_selector.dart';

class AlertsScreen extends StatefulWidget {
  final Isar isar;

  const AlertsScreen({super.key, required this.isar});

  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen>
    with WidgetsBindingObserver {
  List<AlertRule> _alerts = [];
  List<AlertEvent> _events = [];
  bool _isLoading = true;
  String _filter = 'all'; // all, active, inactive
  AppState? _appState;
  bool _isSelectionMode = false;
  Set<int> _selectedAlertIds = {};
  bool _needsRefresh = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Always refresh when screen is opened to ensure Watchlist Alert changes are reflected
    _loadData();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Refresh when app comes to foreground
      _loadData();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _appState = AppStateScope.of(context);
    // Refresh when dependencies change (e.g., when returning from another screen)
    if (_needsRefresh) {
      _needsRefresh = false;
      _loadData();
    }
  }

  @override
  void didUpdateWidget(AlertsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Mark that we need to refresh when dependencies are ready
    _needsRefresh = true;
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
    });

    try {
      // Sync alerts from server if authenticated
      await AlertSyncService.fetchAndSyncAlerts(widget.isar);
      await AlertSyncService.syncPendingAlerts(widget.isar);

      final allAlerts = await widget.isar.alertRules.where().findAll();
      // Filter out Watchlist Alerts - they are background monitoring, not visible in list
      final alerts = allAlerts.where((a) {
        // Exclude alerts with description containing "WATCHLIST:"
        final desc = a.description;
        if (desc == null) return true;
        return !desc.toUpperCase().contains('WATCHLIST:');
      }).toList();

      if (kDebugMode) {
        final watchlistCount = allAlerts
            .where((a) =>
                a.description != null &&
                a.description!.toUpperCase().contains('WATCHLIST:'))
            .length;
        debugPrint(
            'AlertsScreen: Loaded ${allAlerts.length} total alerts (${watchlistCount} Watchlist Alerts, ${allAlerts.length - watchlistCount} custom alerts)');
      }

      final events = await widget.isar.alertEvents.where().findAll();

      setState(() {
        _alerts = alerts;
        _events = events;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
      
      // Log error to server
      ErrorService.logError(
        error: e,
        context: 'alerts_screen_load_data',
      );
      
      if (mounted) {
        final loc = context.loc;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              ErrorService.getUserFriendlyError(e, loc),
            ),
          ),
        );
      }
    }
  }

  List<AlertRule> get _filteredAlerts {
    switch (_filter) {
      case 'active':
        return _alerts.where((a) => a.active).toList();
      case 'inactive':
        return _alerts.where((a) => !a.active).toList();
      default:
        return _alerts;
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;

    // Refresh data when screen becomes visible (e.g., when returning from another screen)
    // This ensures Watchlist Alert changes are reflected immediately
    if (_needsRefresh) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _needsRefresh = false;
          _loadData();
        }
      });
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(loc.t('alerts_title')),
        backgroundColor: Colors.blue[900],
        foregroundColor: Colors.white,
        actions: [
          if (_isSelectionMode) ...[
            IconButton(
              icon: const Icon(Icons.select_all),
              tooltip: 'Select All',
              onPressed: () {
                setState(() {
                  _selectedAlertIds = _filteredAlerts.map((a) => a.id).toSet();
                });
              },
            ),
            IconButton(
              icon: const Icon(Icons.deselect),
              tooltip: 'Deselect All',
              onPressed: () {
                setState(() {
                  _selectedAlertIds.clear();
                });
              },
            ),
            PopupMenuButton<String>(
              onSelected: (value) => _handleBulkAction(value),
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'enable',
                  child: Row(
                    children: [
                      const Icon(Icons.play_arrow),
                      const SizedBox(width: 8),
                      Text(loc.t('common_enable')),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'disable',
                  child: Row(
                    children: [
                      const Icon(Icons.pause),
                      const SizedBox(width: 8),
                      Text(loc.t('common_disable')),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'delete',
                  child: Row(
                    children: [
                      const Icon(Icons.delete, color: Colors.red),
                      const SizedBox(width: 8),
                      Text(
                        loc.t('common_delete'),
                        style: const TextStyle(color: Colors.red),
                      ),
                    ],
                  ),
                ),
              ],
              child: const Icon(Icons.more_vert),
            ),
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Cancel Selection',
              onPressed: () {
                setState(() {
                  _isSelectionMode = false;
                  _selectedAlertIds.clear();
                });
              },
            ),
          ] else ...[
            IconButton(
              icon: const Icon(Icons.checklist),
              tooltip: 'Select Alerts',
              onPressed: () {
                setState(() {
                  _isSelectionMode = true;
                });
              },
            ),
            PopupMenuButton<String>(
              onSelected: (value) {
                setState(() {
                  _filter = value;
                });
              },
              itemBuilder: (context) => [
                PopupMenuItem(value: 'all', child: Text(loc.t('common_all'))),
                PopupMenuItem(
                    value: 'active',
                    child: Text(loc.t('alerts_filter_active'))),
                PopupMenuItem(
                    value: 'inactive',
                    child: Text(loc.t('alerts_filter_inactive'))),
              ],
              child: const Icon(Icons.filter_list),
            ),
          ],
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadData,
              child: Column(
                children: [
                  // Indicator selector
                  if (_appState != null)
                    IndicatorSelector(appState: _appState!),

                  // Statistics
                  _buildStatsCard(loc),

                  // Alerts list
                  Expanded(
                    child: _filteredAlerts.isEmpty
                        ? _buildEmptyState(loc)
                        : ListView.builder(
                            itemCount: _filteredAlerts.length,
                            itemBuilder: (context, index) {
                              final alert = _filteredAlerts[index];
                              return _buildAlertCard(loc, alert);
                            },
                          ),
                  ),
                ],
              ),
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _createAlert(),
        tooltip: loc.t('home_create_alert'),
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildStatsCard(AppLocalizations loc) {
    final activeCount = _alerts.where((a) => a.active).length;
    final totalCount = _alerts.length;
    final recentEvents = _events
        .where((e) =>
            DateTime.now()
                .difference(DateTime.fromMillisecondsSinceEpoch(e.ts * 1000))
                .inDays <
            7)
        .length;

    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _buildStatItem(
                loc.t('alerts_stat_total'), totalCount.toString(), Colors.blue),
            _buildStatItem(loc.t('alerts_stat_active'), activeCount.toString(),
                Colors.green),
            _buildStatItem(loc.t('alerts_stat_week'), recentEvents.toString(),
                Colors.orange),
          ],
        ),
      ),
    );
  }

  Widget _buildStatItem(String label, String value, Color color) {
    return Column(
      children: [
        Text(
          value,
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: Colors.grey[600],
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyState(AppLocalizations loc) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.notifications_off,
            size: 64,
            color: Colors.grey[400],
          ),
          const SizedBox(height: 16),
          Text(
            loc.t('alerts_empty_title'),
            style: TextStyle(
              fontSize: 18,
              color: Colors.grey[600],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            loc.t('alerts_empty_subtitle'),
            style: TextStyle(
              color: Colors.grey[500],
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: _createAlert,
            icon: const Icon(Icons.add_alert),
            label: Text(loc.t('home_create_alert')),
          ),
        ],
      ),
    );
  }

  Widget _buildAlertCard(AppLocalizations loc, AlertRule alert) {
    final isSelected = _selectedAlertIds.contains(alert.id);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      color: isSelected ? Colors.blue[50] : null,
      child: ListTile(
        leading: _isSelectionMode
            ? Checkbox(
                value: isSelected,
                onChanged: (value) {
                  setState(() {
                    if (value == true) {
                      _selectedAlertIds.add(alert.id);
                    } else {
                      _selectedAlertIds.remove(alert.id);
                    }
                  });
                },
              )
            : CircleAvatar(
                backgroundColor: alert.active ? Colors.green : Colors.grey,
                child: Icon(
                  alert.active
                      ? Icons.notifications_active
                      : Icons.notifications_off,
                  color: Colors.white,
                ),
              ),
        title: Text(
          alert.symbol,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_getAlertDescription(alert)),
            Text(
              loc.t(
                'alerts_levels_prefix',
                params: {'levels': alert.levels.join('/')},
              ),
            ),
            if (alert.description != null) Text(alert.description!),
          ],
        ),
        trailing: _isSelectionMode
            ? null
            : PopupMenuButton<String>(
                onSelected: (value) => _handleAlertAction(value, alert),
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'toggle',
                    child: Row(
                      children: [
                        Icon(alert.active ? Icons.pause : Icons.play_arrow),
                        const SizedBox(width: 8),
                        Text(alert.active
                            ? loc.t('common_disable')
                            : loc.t('common_enable')),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'edit',
                    child: Row(
                      children: [
                        const Icon(Icons.edit),
                        const SizedBox(width: 8),
                        Text(loc.t('common_edit')),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'duplicate',
                    child: Row(
                      children: [
                        const Icon(Icons.copy),
                        const SizedBox(width: 8),
                        Text(loc.t('common_duplicate')),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Row(
                      children: [
                        const Icon(Icons.delete, color: Colors.red),
                        const SizedBox(width: 8),
                        Text(
                          loc.t('common_delete'),
                          style: const TextStyle(color: Colors.red),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
        onTap: () {
          if (_isSelectionMode) {
            setState(() {
              if (_selectedAlertIds.contains(alert.id)) {
                _selectedAlertIds.remove(alert.id);
              } else {
                _selectedAlertIds.add(alert.id);
              }
            });
          } else {
            _editAlert(alert);
          }
        },
        onLongPress: () {
          if (!_isSelectionMode) {
            setState(() {
              _isSelectionMode = true;
              _selectedAlertIds.add(alert.id);
            });
          }
        },
      ),
    );
  }

  void _createAlert() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => CreateAlertScreen(isar: widget.isar),
      ),
    ).then((_) => _loadData());
  }

  void _editAlert(AlertRule alert) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) =>
            CreateAlertScreen(isar: widget.isar, alert: alert),
      ),
    ).then((_) => _loadData());
  }

  void _handleAlertAction(String action, AlertRule alert) {
    switch (action) {
      case 'toggle':
        _toggleAlert(alert);
        break;
      case 'edit':
        _editAlert(alert);
        break;
      case 'duplicate':
        _duplicateAlert(alert);
        break;
      case 'delete':
        _deleteAlert(alert);
        break;
    }
  }

  Future<void> _toggleAlert(AlertRule alert) async {
    try {
      await widget.isar.writeTxn(() {
        alert.active = !alert.active;
        return widget.isar.alertRules.put(alert);
      });
      await AlertSyncService.syncAlert(widget.isar, alert);

      if (!mounted) return;
      setState(() {
        final index = _alerts.indexWhere((a) => a.id == alert.id);
        if (index != -1) {
          _alerts[index] = alert;
        }
      });

      if (!mounted) return;
      final loc = context.loc;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            alert.active ? loc.t('alerts_enabled') : loc.t('alerts_disabled'),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      final loc = context.loc;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            loc.t('alerts_error_generic', params: {'message': '$e'}),
          ),
        ),
      );
    }
  }

  Future<void> _duplicateAlert(AlertRule alert) async {
    try {
      final newAlert = AlertRule()
        ..symbol = alert.symbol
        ..timeframe = alert.timeframe
        ..indicator = alert.indicator
        ..period = alert.period
        ..indicatorParams = alert.indicatorParams != null
            ? Map<String, dynamic>.from(alert.indicatorParams!)
            : null
        ..levels = List.from(alert.levels)
        ..mode = alert.mode
        ..cooldownSec = alert.cooldownSec
        ..active = true
        ..alertOnClose = alert.alertOnClose
        ..createdAt = DateTime.now().millisecondsSinceEpoch ~/ 1000
        ..description = '${alert.description ?? ''} (copy)';

      await widget.isar.writeTxn(() {
        return widget.isar.alertRules.put(newAlert);
      });
      await AlertSyncService.syncAlert(widget.isar, newAlert);

      await _loadData();

      if (!mounted) return;
      final loc = context.loc;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(loc.t('alerts_duplicate_success'))),
      );
    } catch (e) {
      if (!mounted) return;
      final loc = context.loc;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            loc.t('alerts_error_generic', params: {'message': '$e'}),
          ),
        ),
      );
    }
  }

  Future<void> _deleteAlert(AlertRule alert) async {
    final loc = context.loc;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(loc.t('alerts_delete_title')),
        content: Text(
            loc.t('alerts_delete_message', params: {'symbol': alert.symbol})),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(loc.t('common_cancel')),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: Text(loc.t('common_delete')),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await widget.isar.writeTxn(() {
          return widget.isar.alertRules.delete(alert.id);
        });
        await AlertSyncService.deleteAlert(alert);

        _loadData();

        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(loc.t('alerts_delete_success'))),
        );
      } catch (e) {
        // Log error to server
        ErrorService.logError(
          error: e,
          context: 'alerts_screen_delete_alert',
          additionalData: {'alertId': alert.id.toString()},
        );
        
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              ErrorService.getUserFriendlyError(e, loc),
            ),
          ),
        );
      }
    }
  }

  String _getAlertDescription(AlertRule alert) {
    final indicatorType = IndicatorType.fromJson(alert.indicator);
    final indicatorName = indicatorType.name.toUpperCase();
    String params = '${alert.period}';

    // Add %D period for Stochastic
    if (indicatorType == IndicatorType.stoch && alert.indicatorParams != null) {
      final dPeriod = alert.indicatorParams?['dPeriod'] as int?;
      if (dPeriod != null) {
        params = '$params/$dPeriod';
      }
    }

    return '${alert.timeframe} • $indicatorName($params)';
  }

  Future<void> _handleBulkAction(String action) async {
    if (_selectedAlertIds.isEmpty) return;

    final selectedAlerts =
        _alerts.where((a) => _selectedAlertIds.contains(a.id)).toList();
    final loc = context.loc;

    // Show loading indicator
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 16),
              Text('Processing ${selectedAlerts.length} alert(s)...'),
            ],
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    }

    try {
      switch (action) {
        case 'enable':
          // Update all alerts in one transaction
          await widget.isar.writeTxn(() async {
            for (final alert in selectedAlerts) {
              alert.active = true;
              await widget.isar.alertRules.put(alert);
            }
          });

          // Sync all alerts in parallel (non-blocking)
          unawaited(Future.wait(
            selectedAlerts
                .map((alert) => AlertSyncService.syncAlert(widget.isar, alert)),
          ));

          // Update UI immediately
          if (mounted) {
            setState(() {
              for (final alert in selectedAlerts) {
                final index = _alerts.indexWhere((a) => a.id == alert.id);
                if (index != -1) {
                  _alerts[index].active = true;
                }
              }
              _isSelectionMode = false;
              _selectedAlertIds.clear();
            });

            ScaffoldMessenger.of(context).hideCurrentSnackBar();
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('${selectedAlerts.length} alert(s) enabled'),
                backgroundColor: Colors.green,
              ),
            );
          }
          return;

        case 'disable':
          // Update all alerts in one transaction
          await widget.isar.writeTxn(() async {
            for (final alert in selectedAlerts) {
              alert.active = false;
              await widget.isar.alertRules.put(alert);
            }
          });

          // Sync all alerts in parallel (non-blocking)
          unawaited(Future.wait(
            selectedAlerts
                .map((alert) => AlertSyncService.syncAlert(widget.isar, alert)),
          ));

          // Update UI immediately
          if (mounted) {
            setState(() {
              for (final alert in selectedAlerts) {
                final index = _alerts.indexWhere((a) => a.id == alert.id);
                if (index != -1) {
                  _alerts[index].active = false;
                }
              }
              _isSelectionMode = false;
              _selectedAlertIds.clear();
            });

            ScaffoldMessenger.of(context).hideCurrentSnackBar();
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('${selectedAlerts.length} alert(s) disabled'),
                backgroundColor: Colors.orange,
              ),
            );
          }
          return;

        case 'delete':
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(loc.t('common_delete')),
              content: Text('Delete ${selectedAlerts.length} alert(s)?'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text(loc.t('common_cancel')),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(
                    loc.t('common_delete'),
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
              ],
            ),
          );

          if (confirmed == true) {
            // Delete all alerts in one transaction
            await widget.isar.writeTxn(() async {
              for (final alert in selectedAlerts) {
                // Delete alert state
                try {
                  final alertState = await widget.isar.alertStates
                      .filter()
                      .ruleIdEqualTo(alert.id)
                      .findFirst();
                  if (alertState != null && alertState.id > 0) {
                    await widget.isar.alertStates.delete(alertState.id);
                  }
                } catch (e) {
                  // Ignore errors
                }

                // Delete alert events
                try {
                  final events = await widget.isar.alertEvents
                      .filter()
                      .ruleIdEqualTo(alert.id)
                      .findAll();
                  for (final event in events) {
                    await widget.isar.alertEvents.delete(event.id);
                  }
                } catch (e) {
                  // Ignore errors
                }

                // Delete alert
                await widget.isar.alertRules.delete(alert.id);
              }
            });

            // Sync deletions in parallel (non-blocking)
            unawaited(Future.wait(
              selectedAlerts.map((alert) =>
                  AlertSyncService.deleteAlert(alert, hardDelete: true)),
            ));

            // Update UI immediately
            if (mounted) {
              setState(() {
                _alerts.removeWhere((a) => _selectedAlertIds.contains(a.id));
                _isSelectionMode = false;
                _selectedAlertIds.clear();
              });

              ScaffoldMessenger.of(context).hideCurrentSnackBar();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('${selectedAlerts.length} alert(s) deleted'),
                  backgroundColor: Colors.red,
                ),
              );
            }
          }
          return;

        default:
          return;
      }
    } catch (e) {
      // Log error to server
      ErrorService.logError(
        error: e,
        context: 'alerts_screen_bulk_action',
        additionalData: {'action': action},
      );
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              ErrorService.getUserFriendlyError(e, loc),
            ),
          ),
        );
      }
    }
  }
}
