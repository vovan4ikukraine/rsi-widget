import 'package:flutter/material.dart';
import 'package:isar/isar.dart';
import '../models.dart';
import 'create_alert_screen.dart';
import '../localization/app_localizations.dart';
import '../services/alert_sync_service.dart';

class AlertsScreen extends StatefulWidget {
  final Isar isar;

  const AlertsScreen({super.key, required this.isar});

  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen> {
  List<AlertRule> _alerts = [];
  List<AlertEvent> _events = [];
  bool _isLoading = true;
  String _filter = 'all'; // all, active, inactive

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
    });

    try {
      // Sync alerts from server if authenticated
      await AlertSyncService.fetchAndSyncAlerts(widget.isar);
      await AlertSyncService.syncPendingAlerts(widget.isar);

      final alerts = await widget.isar.alertRules.where().findAll();

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
      if (mounted) {
        final loc = context.loc;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              loc.t(
                'alerts_error_loading',
                params: {'message': '$e'},
              ),
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

    return Scaffold(
      appBar: AppBar(
        title: Text(loc.t('alerts_title')),
        backgroundColor: Colors.blue[900],
        foregroundColor: Colors.white,
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              setState(() {
                _filter = value;
              });
            },
            itemBuilder: (context) => [
              PopupMenuItem(value: 'all', child: Text(loc.t('common_all'))),
              PopupMenuItem(
                  value: 'active', child: Text(loc.t('alerts_filter_active'))),
              PopupMenuItem(
                  value: 'inactive',
                  child: Text(loc.t('alerts_filter_inactive'))),
            ],
            child: const Icon(Icons.filter_list),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadData,
              child: Column(
                children: [
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
        child: const Icon(Icons.add),
        tooltip: loc.t('home_create_alert'),
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
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: alert.active ? Colors.green : Colors.grey,
          child: Icon(
            alert.active ? Icons.notifications_active : Icons.notifications_off,
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
            Text('${alert.timeframe} • RSI(${alert.rsiPeriod})'),
            Text(
              loc.t(
                'alerts_levels_prefix',
                params: {'levels': alert.levels.join('/')},
              ),
            ),
            if (alert.description != null) Text(alert.description!),
          ],
        ),
        trailing: PopupMenuButton<String>(
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
        onTap: () => _editAlert(alert),
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
        ..rsiPeriod = alert.rsiPeriod
        ..levels = List.from(alert.levels)
        ..mode = alert.mode
        ..cooldownSec = alert.cooldownSec
        ..active = true
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
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              loc.t('alerts_error_generic', params: {'message': '$e'}),
            ),
          ),
        );
      }
    }
  }
}
