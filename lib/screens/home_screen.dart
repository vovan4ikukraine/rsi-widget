import 'package:flutter/material.dart';
import 'package:isar/isar.dart';
import '../models.dart';
import '../services/yahoo_proto.dart';
import '../widgets/rsi_chart.dart';
import 'alerts_screen.dart';
import 'settings_screen.dart';
import 'create_alert_screen.dart';
import 'watchlist_screen.dart';

class HomeScreen extends StatefulWidget {
  final Isar isar;
  final String? initialSymbol;

  const HomeScreen({super.key, required this.isar, this.initialSymbol});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final YahooProtoSource _yahooService =
      YahooProtoSource('https://rsi-workers.vovan4ikukraine.workers.dev');
  List<AlertRule> _alerts = [];
  String _selectedSymbol = 'AAPL';
  String _selectedTimeframe = '15m';
  int _rsiPeriod = 14; // Период RSI
  double _lowerLevel = 30.0; // Нижняя зона (перепроданность)
  double _upperLevel = 70.0; // Верхняя зона (перекупленность)
  List<double> _rsiValues = [];
  List<int> _rsiTimestamps = []; // Временные метки для каждой точки RSI
  double _currentRsi = 0.0;
  bool _isLoading = false;
  bool _rsiSettingsExpanded = false; // Состояние сворачивания настроек RSI

  // Контроллеры для полей ввода
  final TextEditingController _rsiPeriodController = TextEditingController();
  final TextEditingController _lowerLevelController = TextEditingController();
  final TextEditingController _upperLevelController = TextEditingController();
  final TextEditingController _symbolController = TextEditingController();
  bool _isSearchingSymbols = false;

  @override
  void initState() {
    super.initState();
    if (widget.initialSymbol != null) {
      _selectedSymbol = widget.initialSymbol!;
    }
    // Инициализируем контроллер символа
    _symbolController.text = _selectedSymbol;
    // Инициализируем контроллеры (без text, используем hintText)
    _clearControllers();
    _loadAlerts();
    _loadRsiData();
  }

  @override
  void dispose() {
    _rsiPeriodController.dispose();
    _lowerLevelController.dispose();
    _upperLevelController.dispose();
    _symbolController.dispose();
    super.dispose();
  }

  Future<void> _loadAlerts() async {
    final alerts =
        await widget.isar.alertRules.filter().activeEqualTo(true).findAll();
    setState(() {
      _alerts = alerts;
    });
  }

  Future<void> _loadRsiData() async {
    // Сохраняем предыдущий символ для отката в случае ошибки
    final previousSymbol = _selectedSymbol;

    setState(() {
      _isLoading = true;
    });

    try {
      // Увеличиваем limit для больших таймфреймов
      int limit = 100;
      if (_selectedTimeframe == '4h') {
        limit = 500; // Для 4h нужно больше данных (минимум 15 для RSI)
      } else if (_selectedTimeframe == '1d') {
        limit = 730; // Для 1d нужны данные за 2 года (минимум 15 для RSI)
      }

      final candles = await _yahooService.fetchCandles(
        _selectedSymbol,
        _selectedTimeframe,
        limit: limit,
      );

      debugPrint(
          'HomeScreen: Получено ${candles.length} свечей для $_selectedSymbol $_selectedTimeframe (limit был $limit)');

      if (candles.isEmpty) {
        // Откатываем символ обратно, если нет данных
        setState(() {
          _selectedSymbol = previousSymbol;
          _symbolController.text = previousSymbol;
        });

        String message =
            'Нет данных для инструмента на таймфрейме $_selectedTimeframe';
        // Добавляем подсказку для больших таймфреймов и выходных дней
        if (_selectedTimeframe == '4h' || _selectedTimeframe == '1d') {
          final now = DateTime.now();
          final dayOfWeek = now.weekday; // 1 = Monday, 7 = Sunday
          if (dayOfWeek == 6 || dayOfWeek == 7) {
            message +=
                '\nРынки закрыты в выходные дни. Для таймфреймов 4h и 1d Yahoo Finance может не возвращать свежие данные.';
            message += '\nПопробуйте в рабочие дни (понедельник-пятница).';
          } else {
            message +=
                '\nДля больших таймфреймов требуются данные за более длительный период.';
          }
        } else {
          message += '\nПроверьте правильность написания символа.';
        }

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(message),
              duration: const Duration(seconds: 6),
            ),
          );
        }
        setState(() {
          _rsiValues = [];
          _rsiTimestamps = [];
          _currentRsi = 0.0;
        });
        return;
      }

      final closes = candles.map((c) => c.close).toList();

      // Используем правильный алгоритм Wilder для расчета RSI
      // Это стандартный алгоритм, используемый в TradingView и Yahoo Finance
      final rsiValues = <double>[];
      final rsiTimestamps = <int>[]; // Временные метки для каждой точки RSI
      final rsiPeriod = _rsiPeriod;

      if (closes.length < rsiPeriod + 1) {
        // Недостаточно данных
      } else {
        // Расчет первых средних значений (простая средняя)
        double gain = 0, loss = 0;
        for (int i = 1; i <= rsiPeriod; i++) {
          final change = closes[i] - closes[i - 1];
          if (change > 0) {
            gain += change;
          } else {
            loss -= change;
          }
        }

        double au = gain / rsiPeriod; // Average Up
        double ad = loss / rsiPeriod; // Average Down

        // Инкрементальный расчет для остальных точек по формуле Wilder
        for (int i = rsiPeriod + 1; i < closes.length; i++) {
          final change = closes[i] - closes[i - 1];
          final u = change > 0 ? change : 0.0;
          final d = change < 0 ? -change : 0.0;

          // Обновление по формуле Wilder: EMA = (prev * (n-1) + current) / n
          au = (au * (rsiPeriod - 1) + u) / rsiPeriod;
          ad = (ad * (rsiPeriod - 1) + d) / rsiPeriod;

          // Расчет RSI
          if (ad == 0) {
            rsiValues.add(100.0);
          } else {
            final rs = au / ad;
            final rsi = 100 - (100 / (1 + rs));
            rsiValues.add(rsi.clamp(0, 100));
          }

          // Сохраняем временную метку соответствующей свечи
          rsiTimestamps.add(candles[i].timestamp);
        }
      }

      if (rsiValues.isEmpty && closes.length < 15) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                  'Недостаточно данных для расчета RSI. Получено ${candles.length} свечей, требуется минимум 15'),
              duration: const Duration(seconds: 4),
            ),
          );
        }
      }

      // Для отображения графика берем только последние N точек
      // Это улучшает читаемость, особенно для больших таймфреймов
      int maxChartPoints = 100; // Максимум точек для графика
      if (_selectedTimeframe == '4h') {
        maxChartPoints = 60; // Для 4h показываем последние 60 точек (~10 дней)
      } else if (_selectedTimeframe == '1d') {
        maxChartPoints = 90; // Для 1d показываем последние 90 точек (~3 месяца)
      } else if (_selectedTimeframe == '1h') {
        maxChartPoints = 100; // Для 1h показываем последние 100 точек (~4 дня)
      } else {
        maxChartPoints =
            100; // Для минутных таймфреймов показываем последние 100 точек
      }

      // Берем только последние точки для графика
      final chartRsiValues = rsiValues.length > maxChartPoints
          ? rsiValues.sublist(rsiValues.length - maxChartPoints)
          : rsiValues;
      final chartRsiTimestamps = rsiTimestamps.length > maxChartPoints
          ? rsiTimestamps.sublist(rsiTimestamps.length - maxChartPoints)
          : rsiTimestamps;

      setState(() {
        _rsiValues = chartRsiValues;
        _rsiTimestamps = chartRsiTimestamps;
        _currentRsi = rsiValues.isNotEmpty ? rsiValues.last : 0.0;
      });
    } catch (e, stackTrace) {
      // Откатываем символ обратно при ошибке
      setState(() {
        _selectedSymbol = previousSymbol;
        _symbolController.text = previousSymbol;
      });
      // Подробное логирование ошибки
      debugPrint('Ошибка загрузки данных RSI:');
      debugPrint('Символ: $_selectedSymbol');
      debugPrint('Таймфрейм: $_selectedTimeframe');
      debugPrint('Ошибка: $e');
      debugPrint('Stack trace: $stackTrace');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                'Инструмент не найден или нет данных. Проверьте правильность написания символа.'),
            duration: const Duration(seconds: 5),
            action: SnackBarAction(
              label: 'Подробнее',
              onPressed: () {
                showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Детали ошибки'),
                    content: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('Символ: $_selectedSymbol'),
                          Text('Таймфрейм: $_selectedTimeframe'),
                          const SizedBox(height: 8),
                          const Text('Ошибка:',
                              style: TextStyle(fontWeight: FontWeight.bold)),
                          Text('$e'),
                        ],
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Закрыть'),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        );
      }
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('RSI Widget'),
        backgroundColor: Colors.blue[900],
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.bookmark_border),
            tooltip: 'Watchlist',
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => WatchlistScreen(isar: widget.isar),
                ),
              );
              // WatchlistScreen обновляется автоматически при открытии
            },
          ),
          IconButton(
            icon: const Icon(Icons.notifications),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => AlertsScreen(isar: widget.isar),
                ),
              );
              // Обновляем список алертов после возврата
              _loadAlerts();
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const SettingsScreen(),
              ),
            ),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadRsiData,
              child: GestureDetector(
                onTap: () {
                  // Убираем фокус при нажатии на экран
                  FocusScope.of(context).unfocus();
                },
                behavior: HitTestBehavior.opaque,
                child: SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Выбор символа и таймфрейма
                      _buildSymbolSelector(),
                      const SizedBox(height: 16),

                      // Настройки RSI
                      _buildRsiSettingsCard(),
                      const SizedBox(height: 16),

                      // Текущий RSI
                      _buildCurrentRsiCard(),
                      const SizedBox(height: 16),

                      // График RSI
                      _buildRsiChart(),
                      const SizedBox(height: 16),

                      // Активные алерты
                      _buildActiveAlerts(),
                      const SizedBox(height: 16),

                      // Быстрые действия
                      _buildQuickActions(),
                    ],
                  ),
                ),
              ),
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showCreateAlertDialog(),
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildSymbolSelector() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Инструмент',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: Autocomplete<SymbolInfo>(
                    optionsBuilder: (TextEditingValue textEditingValue) async {
                      final query = textEditingValue.text.trim();

                      // Если поле пустое - показываем все популярные
                      if (query.isEmpty) {
                        // Сбрасываем флаг загрузки если он был установлен
                        if (_isSearchingSymbols && mounted) {
                          setState(() {
                            _isSearchingSymbols = false;
                          });
                        }

                        // Показываем все популярные символы
                        try {
                          final popularSymbols =
                              await _yahooService.fetchPopularSymbols();
                          return popularSymbols.map((s) => SymbolInfo(
                                symbol: s,
                                name: s,
                                type: 'unknown',
                                currency: 'USD',
                                exchange: 'Unknown',
                              ));
                        } catch (e) {
                          return const Iterable<SymbolInfo>.empty();
                        }
                      }

                      // Для одного символа также показываем популярные, но фильтруем
                      if (query.length == 1) {
                        if (_isSearchingSymbols && mounted) {
                          setState(() {
                            _isSearchingSymbols = false;
                          });
                        }
                        try {
                          final popularSymbols =
                              await _yahooService.fetchPopularSymbols();
                          // Фильтруем по первому символу
                          final filtered = popularSymbols.where((s) =>
                              s.toUpperCase().startsWith(query.toUpperCase()));
                          return filtered.map((s) => SymbolInfo(
                                symbol: s,
                                name: s,
                                type: 'unknown',
                                currency: 'USD',
                                exchange: 'Unknown',
                              ));
                        } catch (e) {
                          return const Iterable<SymbolInfo>.empty();
                        }
                      }

                      // Для поиска с 2+ символами
                      if (!_isSearchingSymbols && mounted) {
                        setState(() {
                          _isSearchingSymbols = true;
                        });
                      }

                      try {
                        final results =
                            await _yahooService.searchSymbols(query);
                        if (mounted) {
                          setState(() {
                            _isSearchingSymbols = false;
                          });
                        }
                        // Показываем все результаты, не ограничиваем
                        return results;
                      } catch (e) {
                        if (mounted) {
                          setState(() {
                            _isSearchingSymbols = false;
                          });
                        }
                        return const Iterable<SymbolInfo>.empty();
                      }
                    },
                    displayStringForOption: (SymbolInfo option) =>
                        '${option.symbol} - ${option.name}',
                    fieldViewBuilder: (
                      BuildContext context,
                      TextEditingController textEditingController,
                      FocusNode focusNode,
                      VoidCallback onFieldSubmitted,
                    ) {
                      // Синхронизируем контроллер с выбранным символом только один раз при инициализации
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (textEditingController.text !=
                            _symbolController.text) {
                          textEditingController.text = _symbolController.text;
                        }
                      });

                      return TextFormField(
                        controller: textEditingController,
                        focusNode: focusNode,
                        onTap: () {
                          // При нажатии на поле очищаем его, чтобы показать список популярных
                          // Это позволяет быстро выбрать инструмент без необходимости стирать текст
                          if (textEditingController.text.isNotEmpty) {
                            textEditingController.clear();
                            _symbolController.clear();
                          }
                        },
                        onFieldSubmitted: (String value) {
                          // Позволяем вводить символ напрямую, даже если его нет в списке
                          final trimmedValue = value.trim().toUpperCase();
                          if (trimmedValue.isNotEmpty &&
                              trimmedValue != _selectedSymbol) {
                            setState(() {
                              _selectedSymbol = trimmedValue;
                              _symbolController.text = trimmedValue;
                            });
                            _loadRsiData();
                          }
                          // Убираем фокус при отправке
                          focusNode.unfocus();
                          onFieldSubmitted();
                        },
                        decoration: InputDecoration(
                          labelText: 'Символ',
                          hintText: 'Начните вводить символ (например, AAPL)',
                          border: const OutlineInputBorder(),
                          suffixIcon: _isSearchingSymbols
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: Padding(
                                    padding: EdgeInsets.all(12.0),
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                )
                              : null,
                        ),
                        onChanged: (value) {
                          _symbolController.text = value;
                        },
                      );
                    },
                    onSelected: (SymbolInfo selection) {
                      _symbolController.text = selection.symbol;
                      // Обновляем символ и загружаем данные
                      // Если загрузка не удастся, символ будет откатан в _loadRsiData
                      setState(() {
                        _selectedSymbol = selection.symbol;
                      });
                      _loadRsiData();
                      // Убираем фокус после выбора
                      FocusScope.of(context).unfocus();
                    },
                    optionsViewBuilder: (
                      BuildContext context,
                      AutocompleteOnSelected<SymbolInfo> onSelected,
                      Iterable<SymbolInfo> options,
                    ) {
                      return Align(
                        alignment: Alignment.topLeft,
                        child: Material(
                          elevation: 4.0,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 400),
                            child: ListView.builder(
                              padding: EdgeInsets.zero,
                              shrinkWrap: true,
                              itemCount: options.length,
                              itemBuilder: (BuildContext context, int index) {
                                final SymbolInfo option =
                                    options.elementAt(index);
                                return InkWell(
                                  onTap: () {
                                    onSelected(option);
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.all(16.0),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                option.symbol,
                                                style: const TextStyle(
                                                    fontWeight:
                                                        FontWeight.bold),
                                              ),
                                              if (option.name != option.symbol)
                                                Text(
                                                  option.name,
                                                  style: TextStyle(
                                                      fontSize: 12,
                                                      color: Colors.grey[600]),
                                                ),
                                            ],
                                          ),
                                        ),
                                        if (option.type != 'unknown')
                                          Chip(
                                            label: Text(
                                              option.type,
                                              style:
                                                  const TextStyle(fontSize: 10),
                                            ),
                                            padding: EdgeInsets.zero,
                                          ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.bookmark_add),
                  tooltip: 'Добавить в Watchlist',
                  onPressed: () => _addToWatchlist(_selectedSymbol),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _selectedTimeframe,
                    decoration: const InputDecoration(
                      labelText: 'ТФ',
                      border: OutlineInputBorder(),
                      isDense: true,
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 12, vertical: 16),
                    ),
                    style: const TextStyle(fontSize: 14),
                    items: const [
                      DropdownMenuItem(value: '1m', child: Text('1м')),
                      DropdownMenuItem(value: '5m', child: Text('5м')),
                      DropdownMenuItem(value: '15m', child: Text('15м')),
                      DropdownMenuItem(value: '1h', child: Text('1ч')),
                      DropdownMenuItem(value: '4h', child: Text('4ч')),
                      DropdownMenuItem(value: '1d', child: Text('1д')),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        setState(() {
                          _selectedTimeframe = value;
                        });
                        _loadRsiData();
                      }
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCurrentRsiCard() {
    final zone = _getRsiZone(_currentRsi);
    final color = _getZoneColor(zone);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'RSI ($_selectedSymbol)',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _currentRsi.toStringAsFixed(1),
                    style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                      color: color,
                    ),
                  ),
                ],
              ),
            ),
            RsiZoneIndicator(
              rsi: _currentRsi,
              symbol: _selectedSymbol,
              levels: [_lowerLevel, _upperLevel],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRsiChart() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 16), // Уменьшены горизонтальные отступы с 16 до 8
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'График RSI',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            RsiChart(
              rsiValues: _rsiValues,
              timestamps: _rsiTimestamps,
              symbol: _selectedSymbol,
              timeframe: _selectedTimeframe,
              levels: [_lowerLevel, _upperLevel],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActiveAlerts() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Активные алерты',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                TextButton(
                  onPressed: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => AlertsScreen(isar: widget.isar),
                      ),
                    );
                    // Обновляем список алертов после возврата
                    _loadAlerts();
                  },
                  child: const Text('Все'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_alerts.isEmpty)
              const Text('Нет активных алертов')
            else
              ..._alerts.take(3).map((alert) => ListTile(
                    title: Text(alert.symbol),
                    subtitle:
                        Text('${alert.timeframe} • ${alert.levels.join('/')}'),
                    trailing: Icon(
                      alert.active
                          ? Icons.notifications_active
                          : Icons.notifications_off,
                      color: alert.active ? Colors.green : Colors.grey,
                    ),
                    onTap: () => _editAlert(alert),
                  )),
          ],
        ),
      ),
    );
  }

  void _clearControllers() {
    _rsiPeriodController.clear();
    _lowerLevelController.clear();
    _upperLevelController.clear();
  }

  void _applyRsiSettings() {
    // Применяем значения из полей ввода
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
    }

    if (lower != null &&
        lower >= 0 &&
        lower <= 100 &&
        lower < _upperLevel &&
        lower != _lowerLevel) {
      _lowerLevel = lower;
      changed = true;
    }

    if (upper != null &&
        upper >= 0 &&
        upper <= 100 &&
        upper > _lowerLevel &&
        upper != _upperLevel) {
      _upperLevel = upper;
      changed = true;
    }

    // Очищаем поля ввода
    _clearControllers();

    // Пересчитываем RSI если изменился период
    if (changed && period != null) {
      _loadRsiData();
    } else if (changed) {
      setState(() {}); // Обновляем только уровни
    }
  }

  void _resetRsiSettings() {
    setState(() {
      _rsiPeriod = 14;
      _lowerLevel = 30.0;
      _upperLevel = 70.0;
    });
    _clearControllers();
    _loadRsiData();
  }

  Widget _buildRsiSettingsCard() {
    return Card(
      child: Column(
        children: [
          InkWell(
            onTap: () {
              setState(() {
                _rsiSettingsExpanded = !_rsiSettingsExpanded;
                // При разворачивании заполняем поля текущими значениями
                if (_rsiSettingsExpanded) {
                  _rsiPeriodController.text = _rsiPeriod.toString();
                  _lowerLevelController.text = _lowerLevel.toStringAsFixed(0);
                  _upperLevelController.text = _upperLevel.toStringAsFixed(0);
                }
              });
            },
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Text(
                    'Настройки RSI',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  Icon(
                    _rsiSettingsExpanded
                        ? Icons.expand_less
                        : Icons.expand_more,
                  ),
                ],
              ),
            ),
          ),
          if (_rsiSettingsExpanded) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _rsiPeriodController,
                          decoration: const InputDecoration(
                            labelText: 'Период RSI',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          keyboardType: TextInputType.number,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: _lowerLevelController,
                          decoration: const InputDecoration(
                            labelText: 'Нижняя зона',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: _upperLevelController,
                          decoration: const InputDecoration(
                            labelText: 'Верхняя зона',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.refresh, size: 20),
                        tooltip: 'Сбросить до значений по умолчанию',
                        onPressed: _resetRsiSettings,
                        color: Colors.grey[600],
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.check, size: 20),
                        tooltip: 'Применить изменения',
                        onPressed: _applyRsiSettings,
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
    );
  }

  Widget _buildQuickActions() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Быстрые действия',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => _showCreateAlertDialog(),
                    icon: const Icon(Icons.add_alert),
                    label: const Text('Создать алерт'),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => _loadRsiData(),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Обновить'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showCreateAlertDialog() async {
    await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (context) => CreateAlertScreen(isar: widget.isar),
      ),
    );
    // Всегда обновляем список алертов после возврата
    _loadAlerts();
  }

  void _editAlert(AlertRule alert) async {
    await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (context) =>
            CreateAlertScreen(isar: widget.isar, alert: alert),
      ),
    );
    // Всегда обновляем список алертов после возврата
    _loadAlerts();
  }

  Future<void> _addToWatchlist(String symbol) async {
    // Проверяем, не добавлен ли уже этот символ
    final existing = await widget.isar.watchlistItems
        .where()
        .symbolEqualTo(symbol)
        .findFirst();

    if (existing != null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$symbol уже в Watchlist')),
        );
      }
      return;
    }

    // Добавляем в watchlist
    // Сначала получаем все существующие элементы, чтобы убедиться что ID назначается правильно
    final allExistingItems = await widget.isar.watchlistItems.where().findAll();
    debugPrint(
        'HomeScreen: Перед добавлением $symbol уже есть ${allExistingItems.length} элементов');
    if (allExistingItems.isNotEmpty) {
      debugPrint(
          'HomeScreen: Существующие элементы: ${allExistingItems.map((e) => '${e.symbol} (id:${e.id})').toList()}');
    }

    // Вычисляем следующий доступный ID
    int nextId = 1;
    if (allExistingItems.isNotEmpty) {
      final maxId =
          allExistingItems.map((e) => e.id).reduce((a, b) => a > b ? a : b);
      nextId = maxId + 1;
    }
    debugPrint('HomeScreen: Следующий доступный ID: $nextId');

    // Создаем новый элемент с явным ID
    final item = WatchlistItem();
    item.id = nextId; // Явно устанавливаем ID
    item.symbol = symbol;
    item.createdAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    await widget.isar.writeTxn(() {
      // Используем put() с явным ID
      return widget.isar.watchlistItems.put(item);
    });

    debugPrint('HomeScreen: После put() item.id = ${item.id}');

    // Проверяем, что элемент действительно добавлен
    final allItems = await widget.isar.watchlistItems.where().findAll();
    debugPrint(
        'HomeScreen: После добавления $symbol всего элементов: ${allItems.length}');
    debugPrint(
        'HomeScreen: Символы в watchlist: ${allItems.map((e) => '${e.symbol} (id:${e.id})').toList()}');

    // Проверяем, что новый элемент действительно имеет уникальный ID
    final addedItem = await widget.isar.watchlistItems
        .where()
        .symbolEqualTo(symbol)
        .findAll();
    debugPrint(
        'HomeScreen: Найдено элементов с символом $symbol: ${addedItem.length}');
    if (addedItem.length > 1) {
      debugPrint(
          'HomeScreen: ВНИМАНИЕ! Дубликаты для $symbol: ${addedItem.map((e) => e.id).toList()}');
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$symbol добавлен в Watchlist')),
      );
    }
  }

  RsiZone _getRsiZone(double rsi) {
    if (rsi < 30) return RsiZone.below;
    if (rsi > 70) return RsiZone.above;
    return RsiZone.between;
  }

  Color _getZoneColor(RsiZone zone) {
    switch (zone) {
      case RsiZone.below:
        return Colors.red;
      case RsiZone.between:
        return Colors.blue;
      case RsiZone.above:
        return Colors.green;
    }
  }
}
