import 'package:flutter/material.dart';
import 'package:isar/isar.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models.dart';
import '../services/yahoo_proto.dart';
import '../services/widget_service.dart';
import '../widgets/rsi_chart.dart';

class WatchlistScreen extends StatefulWidget {
  final Isar isar;

  const WatchlistScreen({super.key, required this.isar});

  @override
  State<WatchlistScreen> createState() => _WatchlistScreenState();
}

class _WatchlistScreenState extends State<WatchlistScreen>
    with WidgetsBindingObserver {
  final YahooProtoSource _yahooService =
      YahooProtoSource('https://rsi-workers.vovan4ikukraine.workers.dev');
  late final WidgetService _widgetService;

  List<WatchlistItem> _watchlistItems = [];
  final Map<String, _SymbolRsiData> _rsiDataMap = {};
  bool _isLoading = false;
  bool _settingsExpanded = false;

  // Настройки для всех графиков
  String _timeframe = '15m';
  int _rsiPeriod = 14;
  double _lowerLevel = 30.0;
  double _upperLevel = 70.0;

  // Контроллеры для полей ввода настроек
  final TextEditingController _rsiPeriodController = TextEditingController();
  final TextEditingController _lowerLevelController = TextEditingController();
  final TextEditingController _upperLevelController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _widgetService = WidgetService(
      isar: widget.isar,
      yahooService: _yahooService,
    );
    WidgetsBinding.instance.addObserver(this);
    _updateControllerHints();
    _loadSavedState();
  }

  Future<void> _loadSavedState() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _timeframe = prefs.getString('watchlist_timeframe') ?? '15m';
      _rsiPeriod = prefs.getInt('watchlist_rsi_period') ?? 14;
      _lowerLevel = prefs.getDouble('watchlist_lower_level') ?? 30.0;
      _upperLevel = prefs.getDouble('watchlist_upper_level') ?? 70.0;
    });
    // Сохраняем период для виджета при инициализации
    await prefs.setInt('rsi_widget_period', _rsiPeriod);
    await prefs.setString('rsi_widget_timeframe', _timeframe);
    _loadWatchlist();
  }

  Future<void> _saveState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('watchlist_timeframe', _timeframe);
    await prefs.setInt('watchlist_rsi_period', _rsiPeriod);
    await prefs.setDouble('watchlist_lower_level', _lowerLevel);
    await prefs.setDouble('watchlist_upper_level', _upperLevel);
  }

  // Перезагружаем список при возвращении приложения из фона
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadWatchlist();
      // Проверяем, изменился ли таймфрейм в виджете и обновляем данные
      _checkWidgetTimeframe();
    }
  }

  Future<void> _checkWidgetTimeframe() async {
    // Загружаем таймфрейм и период из виджета (если были изменены в виджете)
    final prefs = await SharedPreferences.getInstance();
    final widgetTimeframe = prefs.getString('rsi_widget_timeframe');
    final widgetPeriod = prefs.getInt('rsi_widget_period');
    final widgetNeedsRefresh = prefs.getBool('widget_needs_refresh') ?? false;

    bool needsUpdate = false;

    // Если таймфрейм изменился в виджете, обновляем его в приложении
    if (widgetTimeframe != null && widgetTimeframe != _timeframe) {
      setState(() {
        _timeframe = widgetTimeframe;
      });
      _saveState();
      needsUpdate = true;
    }

    // Если период изменился в виджете, обновляем его в приложении
    if (widgetPeriod != null && widgetPeriod != _rsiPeriod) {
      setState(() {
        _rsiPeriod = widgetPeriod;
      });
      _saveState();
      needsUpdate = true;
    }

    // Если виджет запросил обновление или что-то изменилось, перезагружаем данные
    if (needsUpdate || widgetNeedsRefresh) {
      // Сбрасываем флаг обновления
      if (widgetNeedsRefresh) {
        await prefs.remove('widget_needs_refresh');
      }
      _loadAllRsiData();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _rsiPeriodController.dispose();
    _lowerLevelController.dispose();
    _upperLevelController.dispose();
    super.dispose();
  }

  void _updateControllerHints() {
    _rsiPeriodController.clear();
    _lowerLevelController.clear();
    _upperLevelController.clear();
  }

  Future<void> _loadWatchlist() async {
    try {
      // Загружаем все элементы из базы
      final items = await widget.isar.watchlistItems.where().findAll();
      debugPrint(
          'WatchlistScreen: Загружено ${items.length} элементов из базы');

      if (items.isEmpty) {
        debugPrint('WatchlistScreen: База данных пуста!');
        setState(() {
          _watchlistItems = [];
          _rsiDataMap.clear();
        });
        return;
      }

      debugPrint(
          'WatchlistScreen: Символы: ${items.map((e) => '${e.symbol} (id:${e.id}, createdAt:${e.createdAt})').toList()}');

      // Сортируем по дате создания (самые старые первые, новые последние)
      final sortedItems = List<WatchlistItem>.from(items);
      sortedItems.sort((a, b) => a.createdAt.compareTo(b.createdAt));

      debugPrint(
          'WatchlistScreen: После сортировки: ${sortedItems.map((e) => e.symbol).toList()}');

      setState(() {
        _watchlistItems = sortedItems;
        debugPrint(
            'WatchlistScreen: После setState _watchlistItems.length = ${_watchlistItems.length}');
        debugPrint(
            'WatchlistScreen: _watchlistItems содержит: ${_watchlistItems.map((e) => e.symbol).toList()}');
      });

      // Загружаем RSI данные для всех символов
      await _loadAllRsiData();
      // Обновляем виджет после загрузки watchlist (используем сохраненные настройки виджета или текущие)
      _widgetService.updateWidget();
    } catch (e, stackTrace) {
      debugPrint('WatchlistScreen: Ошибка загрузки списка: $e');
      debugPrint('WatchlistScreen: Stack trace: $stackTrace');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка загрузки watchlist: $e')),
        );
      }
    }
  }

  Future<void> _loadAllRsiData() async {
    if (_watchlistItems.isEmpty) return;

    setState(() {
      _isLoading = true;
    });

    try {
      for (final item in _watchlistItems) {
        await _loadRsiDataForSymbol(item.symbol);
      }
    } finally {
      setState(() {
        _isLoading = false;
      });
      // Обновляем виджет после загрузки данных (используем сохраненные настройки виджета)
      _widgetService.updateWidget();
    }
  }

  Future<void> _loadRsiDataForSymbol(String symbol) async {
    try {
      // Определяем limit в зависимости от таймфрейма
      int limit = 100;
      if (_timeframe == '4h') {
        limit = 500;
      } else if (_timeframe == '1d') {
        limit = 730;
      }

      final candles = await _yahooService.fetchCandles(
        symbol,
        _timeframe,
        limit: limit,
      );

      if (candles.isEmpty) {
        setState(() {
          _rsiDataMap[symbol] = _SymbolRsiData(
            rsi: 0.0,
            rsiValues: [],
            timestamps: [],
          );
        });
        return;
      }

      final closes = candles.map((c) => c.close).toList();
      final rsiValues = <double>[];
      final rsiTimestamps = <int>[];

      if (closes.length < _rsiPeriod + 1) {
        setState(() {
          _rsiDataMap[symbol] = _SymbolRsiData(
            rsi: 0.0,
            rsiValues: [],
            timestamps: [],
          );
        });
        return;
      }

      // Расчет RSI по алгоритму Wilder
      double gain = 0, loss = 0;
      for (int i = 1; i <= _rsiPeriod; i++) {
        final change = closes[i] - closes[i - 1];
        if (change > 0) {
          gain += change;
        } else {
          loss -= change;
        }
      }

      double au = gain / _rsiPeriod;
      double ad = loss / _rsiPeriod;

      for (int i = _rsiPeriod + 1; i < closes.length; i++) {
        final change = closes[i] - closes[i - 1];
        final u = change > 0 ? change : 0.0;
        final d = change < 0 ? -change : 0.0;

        au = (au * (_rsiPeriod - 1) + u) / _rsiPeriod;
        ad = (ad * (_rsiPeriod - 1) + d) / _rsiPeriod;

        if (ad == 0) {
          rsiValues.add(100.0);
        } else {
          final rs = au / ad;
          final rsi = 100 - (100 / (1 + rs));
          rsiValues.add(rsi.clamp(0, 100));
        }

        rsiTimestamps.add(candles[i].timestamp);
      }

      // Берем только последние 50 точек для компактного графика
      final chartRsiValues = rsiValues.length > 50
          ? rsiValues.sublist(rsiValues.length - 50)
          : rsiValues;
      final chartRsiTimestamps = rsiTimestamps.length > 50
          ? rsiTimestamps.sublist(rsiTimestamps.length - 50)
          : rsiTimestamps;

      setState(() {
        _rsiDataMap[symbol] = _SymbolRsiData(
          rsi: rsiValues.isNotEmpty ? rsiValues.last : 0.0,
          rsiValues: chartRsiValues,
          timestamps: chartRsiTimestamps,
        );
      });
    } catch (e) {
      debugPrint('Ошибка загрузки RSI для $symbol: $e');
      setState(() {
        _rsiDataMap[symbol] = _SymbolRsiData(
          rsi: 0.0,
          rsiValues: [],
          timestamps: [],
        );
      });
    }
  }

  Future<void> _removeFromWatchlist(WatchlistItem item) async {
    await widget.isar.writeTxn(() {
      return widget.isar.watchlistItems.delete(item.id);
    });
    setState(() {
      _watchlistItems.remove(item);
      _rsiDataMap.remove(item.symbol);
    });
    // Обновляем виджет после удаления
    _widgetService.updateWidget();
  }

  Future<void> _applySettings() async {
    final period = int.tryParse(_rsiPeriodController.text);
    final lower = double.tryParse(_lowerLevelController.text);
    final upper = double.tryParse(_upperLevelController.text);

    bool changed = false;

    if (period != null &&
        period >= 2 &&
        period <= 100 &&
        period != _rsiPeriod) {
      _rsiPeriod = period;
      changed = true;
      _saveState();
    }

    if (lower != null &&
        lower >= 0 &&
        lower <= 100 &&
        lower < _upperLevel &&
        lower != _lowerLevel) {
      _lowerLevel = lower;
      changed = true;
      _saveState();
    }

    if (upper != null &&
        upper >= 0 &&
        upper <= 100 &&
        upper > _lowerLevel &&
        upper != _upperLevel) {
      _upperLevel = upper;
      changed = true;
      _saveState();
    }

    _updateControllerHints();

    if (changed) {
      // Сохраняем период для виджета
      if (period != null) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt('rsi_widget_period', _rsiPeriod);
      }
      _loadAllRsiData();
      // Обновляем виджет с новым периодом
      _widgetService.updateWidget(
        rsiPeriod: _rsiPeriod,
      );
    } else {
      setState(() {});
    }
  }

  Future<void> _resetSettings() async {
    setState(() {
      _timeframe = '15m';
      _rsiPeriod = 14;
      _lowerLevel = 30.0;
      _upperLevel = 70.0;
    });
    _saveState();
    // Сохраняем период для виджета
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('rsi_widget_period', _rsiPeriod);
    _updateControllerHints();
    _loadAllRsiData();
    // Обновляем виджет
    _widgetService.updateWidget(
      timeframe: _timeframe,
      rsiPeriod: _rsiPeriod,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Watchlist'),
        backgroundColor: Colors.blue[900],
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          // Выпадающий бар с настройками
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                InkWell(
                  onTap: () {
                    setState(() {
                      _settingsExpanded = !_settingsExpanded;
                      // При разворачивании заполняем поля текущими значениями
                      if (_settingsExpanded) {
                        _rsiPeriodController.text = _rsiPeriod.toString();
                        _lowerLevelController.text =
                            _lowerLevel.toStringAsFixed(0);
                        _upperLevelController.text =
                            _upperLevel.toStringAsFixed(0);
                      }
                    });
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        const Text(
                          'Настройки Watchlist',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                        const Spacer(),
                        Icon(_settingsExpanded
                            ? Icons.expand_less
                            : Icons.expand_more),
                      ],
                    ),
                  ),
                ),
                if (_settingsExpanded) ...[
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Expanded(
                              flex: 2,
                              child: DropdownButtonFormField<String>(
                                value: _timeframe,
                                decoration: const InputDecoration(
                                  labelText: 'ТФ',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                  contentPadding: EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 8),
                                ),
                                items: const [
                                  DropdownMenuItem(
                                      value: '1m', child: Text('1м')),
                                  DropdownMenuItem(
                                      value: '5m', child: Text('5м')),
                                  DropdownMenuItem(
                                      value: '15m', child: Text('15м')),
                                  DropdownMenuItem(
                                      value: '1h', child: Text('1ч')),
                                  DropdownMenuItem(
                                      value: '4h', child: Text('4ч')),
                                  DropdownMenuItem(
                                      value: '1d', child: Text('1д')),
                                ],
                                onChanged: (value) async {
                                  if (value != null) {
                                    setState(() {
                                      _timeframe = value;
                                    });
                                    _saveState();
                                    // Сохраняем таймфрейм для виджета
                                    final prefs =
                                        await SharedPreferences.getInstance();
                                    await prefs.setString(
                                        'rsi_widget_timeframe', _timeframe);
                                    await prefs.setInt(
                                        'rsi_widget_period', _rsiPeriod);
                                    _loadAllRsiData(); // Автоматически перезагружаем данные при изменении таймфрейма
                                    // Обновляем виджет
                                    _widgetService.updateWidget(
                                      timeframe: _timeframe,
                                      rsiPeriod: _rsiPeriod,
                                    );
                                  }
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextField(
                                controller: _rsiPeriodController,
                                decoration: const InputDecoration(
                                  labelText: 'Период RSI',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                  contentPadding: EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 8),
                                ),
                                keyboardType: TextInputType.number,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextField(
                                controller: _lowerLevelController,
                                decoration: const InputDecoration(
                                  labelText: 'Нижняя зона',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                  contentPadding: EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 8),
                                ),
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                        decimal: true),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextField(
                                controller: _upperLevelController,
                                decoration: const InputDecoration(
                                  labelText: 'Верхняя зона',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                  contentPadding: EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 8),
                                ),
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                        decimal: true),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.refresh, size: 18),
                              tooltip: 'Сбросить',
                              onPressed: _resetSettings,
                              color: Colors.grey[600],
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                            ),
                            const SizedBox(width: 8),
                            IconButton(
                              icon: const Icon(Icons.check, size: 18),
                              tooltip: 'Применить',
                              onPressed: _applySettings,
                              color: Colors.blue,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          // Список инструментов
          Expanded(
            child: _isLoading && _watchlistItems.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : _watchlistItems.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.list, size: 64, color: Colors.grey[400]),
                            const SizedBox(height: 16),
                            Text(
                              'Watchlist пуст',
                              style: TextStyle(
                                  color: Colors.grey[400], fontSize: 18),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Добавьте инструменты с главного экрана',
                              style: TextStyle(
                                  color: Colors.grey[600], fontSize: 14),
                            ),
                          ],
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: () async {
                          await _loadWatchlist(); // Перезагружаем весь список, а не только RSI данные
                        },
                        child: _watchlistItems.isEmpty
                            ? const Center(child: Text('Нет элементов'))
                            : Builder(
                                builder: (context) {
                                  debugPrint(
                                      'WatchlistScreen: ListView.builder будет отображать ${_watchlistItems.length} элементов');
                                  return ListView.builder(
                                    key: ValueKey(
                                        'watchlist_${_watchlistItems.length}'), // Ключ для принудительного обновления
                                    padding:
                                        const EdgeInsets.symmetric(vertical: 8),
                                    itemCount: _watchlistItems.length,
                                    itemBuilder: (context, index) {
                                      if (index >= _watchlistItems.length) {
                                        debugPrint(
                                            'WatchlistScreen: ОШИБКА! Индекс $index >= длины списка ${_watchlistItems.length}');
                                        return const SizedBox.shrink();
                                      }

                                      final item = _watchlistItems[index];
                                      debugPrint(
                                          'WatchlistScreen: Отображение элемента $index: ${item.symbol} (id: ${item.id})');

                                      final rsiData =
                                          _rsiDataMap[item.symbol] ??
                                              _SymbolRsiData(
                                                rsi: 0.0,
                                                rsiValues: [],
                                                timestamps: [],
                                              );

                                      return _buildWatchlistItem(item, rsiData);
                                    },
                                  );
                                },
                              ),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildWatchlistItem(WatchlistItem item, _SymbolRsiData rsiData) {
    final rsi = rsiData.rsi;
    Color rsiColor = Colors.grey;
    if (rsi < _lowerLevel) {
      rsiColor = Colors.red;
    } else if (rsi > _upperLevel) {
      rsiColor = Colors.green;
    } else {
      rsiColor = Colors.blue;
    }

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: InkWell(
        onLongPress: () {
          showDialog(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Удалить из Watchlist?'),
              content: Text('Удалить ${item.symbol} из списка отслеживания?'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Отмена'),
                ),
                ElevatedButton(
                  onPressed: () {
                    Navigator.pop(context);
                    _removeFromWatchlist(item);
                  },
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                  child: const Text('Удалить'),
                ),
              ],
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Text(
                    item.symbol,
                    style: const TextStyle(
                      fontSize: 14, // Уменьшен размер шрифта с 16 до 14
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    'RSI: ${rsi.toStringAsFixed(1)}',
                    style: TextStyle(
                      fontSize: 11,
                      color: rsiColor,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              if (rsiData.rsiValues.isNotEmpty)
                SizedBox(
                  height: 53, // Увеличено с 50 до 53 (примерно на 5%)
                  child: RsiChart(
                    rsiValues: rsiData.rsiValues,
                    timestamps: rsiData.timestamps,
                    symbol: item.symbol,
                    timeframe: _timeframe,
                    levels: [_lowerLevel, _upperLevel],
                    showGrid: false,
                    showLabels: true, // Включаем подписи для оси Y
                    lineWidth: 1.2,
                    isInteractive: false, // Но tooltip все равно будет работать
                  ),
                )
              else
                SizedBox(
                  height: 53, // Увеличено с 50 до 53 (примерно на 5%)
                  child: Center(
                    child: Text(
                      'Нет данных',
                      style: TextStyle(color: Colors.grey[600], fontSize: 11),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SymbolRsiData {
  final double rsi;
  final List<double> rsiValues;
  final List<int> timestamps;

  _SymbolRsiData({
    required this.rsi,
    required this.rsiValues,
    required this.timestamps,
  });
}
