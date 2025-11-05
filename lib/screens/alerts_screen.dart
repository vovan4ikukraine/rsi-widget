import 'package:flutter/material.dart';
import 'package:isar/isar.dart';
import '../models.dart';
import 'create_alert_screen.dart';

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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка загрузки данных: $e')),
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('RSI Алерты'),
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
              const PopupMenuItem(value: 'all', child: Text('Все')),
              const PopupMenuItem(value: 'active', child: Text('Активные')),
              const PopupMenuItem(value: 'inactive', child: Text('Неактивные')),
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
                  // Статистика
                  _buildStatsCard(),

                  // Список алертов
                  Expanded(
                    child: _filteredAlerts.isEmpty
                        ? _buildEmptyState()
                        : ListView.builder(
                            itemCount: _filteredAlerts.length,
                            itemBuilder: (context, index) {
                              final alert = _filteredAlerts[index];
                              return _buildAlertCard(alert);
                            },
                          ),
                  ),
                ],
              ),
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _createAlert(),
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildStatsCard() {
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
            _buildStatItem('Всего', totalCount.toString(), Colors.blue),
            _buildStatItem('Активные', activeCount.toString(), Colors.green),
            _buildStatItem('За неделю', recentEvents.toString(), Colors.orange),
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

  Widget _buildEmptyState() {
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
            'Нет алертов',
            style: TextStyle(
              fontSize: 18,
              color: Colors.grey[600],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Создайте свой первый RSI алерт',
            style: TextStyle(
              color: Colors.grey[500],
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: _createAlert,
            icon: const Icon(Icons.add_alert),
            label: const Text('Создать алерт'),
          ),
        ],
      ),
    );
  }

  Widget _buildAlertCard(AlertRule alert) {
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
            Text('Уровни: ${alert.levels.join('/')}'),
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
                  Text(alert.active ? 'Отключить' : 'Включить'),
                ],
              ),
            ),
            const PopupMenuItem(
              value: 'edit',
              child: Row(
                children: [
                  Icon(Icons.edit),
                  SizedBox(width: 8),
                  Text('Редактировать'),
                ],
              ),
            ),
            const PopupMenuItem(
              value: 'duplicate',
              child: Row(
                children: [
                  Icon(Icons.copy),
                  SizedBox(width: 8),
                  Text('Дублировать'),
                ],
              ),
            ),
            const PopupMenuItem(
              value: 'delete',
              child: Row(
                children: [
                  Icon(Icons.delete, color: Colors.red),
                  SizedBox(width: 8),
                  Text('Удалить', style: TextStyle(color: Colors.red)),
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

      if (!mounted) return;
      setState(() {
        final index = _alerts.indexWhere((a) => a.id == alert.id);
        if (index != -1) {
          _alerts[index] = alert;
        }
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            alert.active ? 'Алерт включен' : 'Алерт отключен',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка: $e')),
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
        ..hysteresis = alert.hysteresis
        ..cooldownSec = alert.cooldownSec
        ..active = true
        ..createdAt = DateTime.now().millisecondsSinceEpoch ~/ 1000
        ..description = '${alert.description ?? ''} (копия)';

      await widget.isar.writeTxn(() {
        return widget.isar.alertRules.put(newAlert);
      });

      _loadData();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Алерт скопирован')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка: $e')),
      );
    }
  }

  Future<void> _deleteAlert(AlertRule alert) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить алерт'),
        content:
            Text('Вы уверены, что хотите удалить алерт для ${alert.symbol}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await widget.isar.writeTxn(() {
          return widget.isar.alertRules.delete(alert.id);
        });

        _loadData();

        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Алерт удален')),
        );
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка: $e')),
        );
      }
    }
  }
}
