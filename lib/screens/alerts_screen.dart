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
import '../utils/context_extensions.dart';
import '../utils/snackbar_helper.dart';
import '../constants/app_constants.dart';
import '../di/app_container.dart';
import '../repositories/i_alert_repository.dart';

class AlertsScreen extends StatefulWidget {
  final Isar isar;

  const AlertsScreen({super.key, required this.isar});

  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen>
    with WidgetsBindingObserver {
  late final IAlertRepository _alertRepository;
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
    _alertRepository = sl<IAlertRepository>();
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
      await AlertSyncService.fetchAndSyncAlerts();
      await AlertSyncService.syncPendingAlerts();

      // Get custom alerts (excludes watchlist alerts)
      final alerts = await _alertRepository.getCustomAlerts();

      if (kDebugMode) {
        final allAlerts = await _alertRepository.getAllAlerts();
        final watchlistCount = allAlerts
            .where((a) =>
                a.description != null &&
                a.description!.toUpperCase().contains(AppConstants.watchlistAlertPrefix))
            .length;
        debugPrint(
            'AlertsScreen: Loaded ${allAlerts.length} total alerts ($watchlistCount Watchlist Alerts, ${alerts.length} custom alerts)');
      }

      final events = await _alertRepository.getAllAlertEvents();

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
        context.showError(ErrorService.getUserFriendlyError(e, context.loc));
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
        titleSpacing: 8, // Reduce spacing between back button and title
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
                        ? Column(
                            children: [
                              // Counter always visible
                              Padding(
                                padding: const EdgeInsets.only(left: 16, top: 4, bottom: 8),
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    '${_alerts.length}/${AppConstants.maxCustomAlerts}',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey[600],
                                    ),
                                  ),
                                ),
                              ),
                              // Empty state
                              Expanded(child: _buildEmptyState(loc)),
                            ],
                          )
                        : ListView.builder(
                            itemCount: _filteredAlerts.length + 1, // +1 for counter
                            itemBuilder: (context, index) {
                              // First item is the counter
                              if (index == 0) {
                                return Padding(
                                  padding: const EdgeInsets.only(left: 16, top: 4, bottom: 8),
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      '${_alerts.length}/${AppConstants.maxCustomAlerts}',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey[600],
                                      ),
                                    ),
                                  ),
                                );
                              }
                              
                              // Adjust index for alerts
                              final alertIndex = index - 1;
                              if (alertIndex >= _filteredAlerts.length) {
                                return const SizedBox.shrink();
                              }
                              
                              final alert = _filteredAlerts[alertIndex];
                              return _buildAlertCard(loc, alert);
                            },
                          ),
                  ),
                ],
              ),
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _alerts.length >= AppConstants.maxCustomAlerts ? null : () => _createAlert(),
        tooltip: _alerts.length >= AppConstants.maxCustomAlerts 
            ? loc.t('create_alert_limit_reached', params: {'max': AppConstants.maxCustomAlerts.toString()})
            : loc.t('home_create_alert'),
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
      case 'delete':
        _deleteAlert(alert);
        break;
    }
  }

  Future<void> _toggleAlert(AlertRule alert) async {
    try {
      alert.active = !alert.active;
      await _alertRepository.saveAlert(alert);
      await AlertSyncService.syncAlert(alert);

      if (!mounted) return;
      setState(() {
        final index = _alerts.indexWhere((a) => a.id == alert.id);
        if (index != -1) {
          _alerts[index] = alert;
        }
      });

      if (!mounted) return;
      final loc = context.loc;
      context.showSuccess(
        alert.active ? loc.t('alerts_enabled') : loc.t('alerts_disabled'),
      );
    } catch (e) {
      if (!mounted) return;
      context.showError(
        context.loc.t('alerts_error_generic', params: {'message': '$e'}),
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
        await _alertRepository.deleteAlert(alert.id);
        await AlertSyncService.deleteAlert(alert);

        _loadData();

        if (!mounted) return;
        context.showSuccess(loc.t('alerts_delete_success'));
      } catch (e) {
        // Log error to server
        ErrorService.logError(
          error: e,
          context: 'alerts_screen_delete_alert',
          additionalData: {'alertId': alert.id.toString()},
        );
        
        if (!mounted) return;
        context.showError(ErrorService.getUserFriendlyError(e, loc));
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
      context.showLoading(
        loc.t('alerts_bulk_processing', params: {'count': '${selectedAlerts.length}'}),
      );
    }

    try {
      switch (action) {
        case 'enable':
          // Update all alerts in one transaction
          for (final alert in selectedAlerts) {
            alert.active = true;
          }
          await _alertRepository.saveAlerts(selectedAlerts);

          // Sync all alerts in parallel (non-blocking)
          unawaited(Future.wait(
            selectedAlerts
                .map((alert) => AlertSyncService.syncAlert(alert)),
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

            context.hideSnackBar();
            context.showSuccess(
              loc.t('alerts_bulk_enabled', params: {'count': '${selectedAlerts.length}'}),
            );
          }
          return;

        case 'disable':
          // Update all alerts in one transaction
          for (final alert in selectedAlerts) {
            alert.active = false;
          }
          await _alertRepository.saveAlerts(selectedAlerts);

          // Sync all alerts in parallel (non-blocking)
          unawaited(Future.wait(
            selectedAlerts
                .map((alert) => AlertSyncService.syncAlert(alert)),
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

            context.hideSnackBar();
            SnackBarHelper.showInfo(
              context,
              loc.t('alerts_bulk_disabled', params: {'count': '${selectedAlerts.length}'}),
            );
          }
          return;

        case 'delete':
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(loc.t('common_delete')),
              content: Text(
                loc.t('alerts_bulk_delete_confirm', params: {'count': '${selectedAlerts.length}'}),
              ),
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

          if (confirmed != true) {
            if (mounted) context.hideSnackBar();
            return;
          }

          {
            // Delete all alerts
            final alertIds = selectedAlerts.map((a) => a.id).toList();
            await _alertRepository.deleteAlerts(alertIds);

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

            context.hideSnackBar();
            context.showSuccess(
              loc.t('alerts_bulk_deleted', params: {'count': '${selectedAlerts.length}'}),
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
        context.hideSnackBar();
        context.showError(ErrorService.getUserFriendlyError(e, loc));
      }
    }
  }
}
