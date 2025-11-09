import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:isar/isar.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models.dart';
import '../services/yahoo_proto.dart';
import '../services/widget_service.dart';
import '../widgets/rsi_chart.dart';
import '../localization/app_localizations.dart';
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
  static const MethodChannel _channel =
      MethodChannel('com.example.rsi_widget/widget');
  late final WidgetService _widgetService;
  List<AlertRule> _alerts = [];
  String _selectedSymbol = 'AAPL';
  String _selectedTimeframe = '15m';
  int _rsiPeriod = 14; // RSI period
  double _lowerLevel = 30.0; // Lower zone (oversold)
  double _upperLevel = 70.0; // Upper zone (overbought)
  List<double> _rsiValues = [];
  List<int> _rsiTimestamps = []; // Timestamps for each RSI point
  double _currentRsi = 0.0;
  bool _isLoading = false;
  bool _rsiSettingsExpanded = false; // RSI settings expansion state

  // Controllers for input fields
  final TextEditingController _rsiPeriodController = TextEditingController();
  final TextEditingController _lowerLevelController = TextEditingController();
  final TextEditingController _upperLevelController = TextEditingController();
  final TextEditingController _symbolController = TextEditingController();
  bool _isSearchingSymbols = false;

  @override
  void initState() {
    super.initState();
    _widgetService = WidgetService(
      isar: widget.isar,
      yahooService: _yahooService,
    );
    _setupMethodChannel();
    _loadSavedState();
  }

  void _setupMethodChannel() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'refreshWidget') {
        final timeframe = call.arguments['timeframe'] as String? ?? '15m';
        final rsiPeriod = call.arguments['rsiPeriod'] as int? ?? 14;
        final minimizeAfterUpdate =
            call.arguments['minimizeAfterUpdate'] as bool? ?? false;

        print(
            'HomeScreen: Refresh widget requested - timeframe: $timeframe, period: $rsiPeriod, minimize: $minimizeAfterUpdate');

        // Update widget with specified timeframe and period
        await _widgetService.updateWidget(
          timeframe: timeframe,
          rsiPeriod: rsiPeriod,
        );

        print('HomeScreen: Widget updated successfully');

        // Small additional delay to ensure data is loaded
        // Native part minimizes application after 2 seconds
      }
    });
  }

  Future<void> _loadSavedState() async {
    final prefs = await SharedPreferences.getInstance();

    if (widget.initialSymbol != null) {
      _selectedSymbol = widget.initialSymbol!;
    } else {
      _selectedSymbol = prefs.getString('home_selected_symbol') ?? 'AAPL';
    }

    _selectedTimeframe = prefs.getString('home_selected_timeframe') ?? '15m';
    _rsiPeriod = prefs.getInt('home_rsi_period') ?? 14;
    _lowerLevel = prefs.getDouble('home_lower_level') ?? 30.0;
    _upperLevel = prefs.getDouble('home_upper_level') ?? 70.0;

    // Initialize symbol controller
    _symbolController.text = _selectedSymbol;
    // Initialize controllers (without text, use hintText)
    _clearControllers();

    setState(() {});

    _loadAlerts();
    _loadRsiData();
  }

  Future<void> _saveState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('home_selected_symbol', _selectedSymbol);
    await prefs.setString('home_selected_timeframe', _selectedTimeframe);
    await prefs.setInt('home_rsi_period', _rsiPeriod);
    await prefs.setDouble('home_lower_level', _lowerLevel);
    await prefs.setDouble('home_upper_level', _upperLevel);
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
    // Save previous symbol for rollback in case of error
    final previousSymbol = _selectedSymbol;

    setState(() {
      _isLoading = true;
    });

    final loc = context.loc;

    try {
      // Increase limit for large timeframes
      int limit = 100;
      if (_selectedTimeframe == '4h') {
        limit = 500; // For 4h need more data (minimum 15 for RSI)
      } else if (_selectedTimeframe == '1d') {
        limit = 730; // For 1d need 2 years of data (minimum 15 for RSI)
      }

      final candles = await _yahooService.fetchCandles(
        _selectedSymbol,
        _selectedTimeframe,
        limit: limit,
      );

      debugPrint(
          'HomeScreen: Received ${candles.length} candles for $_selectedSymbol $_selectedTimeframe (limit was $limit)');

      if (candles.isEmpty) {
        // Rollback symbol if no data
        setState(() {
          _selectedSymbol = previousSymbol;
          _symbolController.text = previousSymbol;
        });

        String message = loc.t('home_no_data_for_timeframe',
            params: {'timeframe': _selectedTimeframe});
        // Add hint for large timeframes and weekends
        if (_selectedTimeframe == '4h' || _selectedTimeframe == '1d') {
          final now = DateTime.now();
          final dayOfWeek = now.weekday; // 1 = Monday, 7 = Sunday
          if (dayOfWeek == 6 || dayOfWeek == 7) {
            message += '\n${loc.t('home_weekend_hint')}';
          } else {
            message += '\n${loc.t('home_large_timeframe_hint')}';
          }
        } else {
          message += '\n${loc.t('home_check_symbol_hint')}';
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

      // Use correct Wilder's algorithm for RSI calculation
      // This is the standard algorithm used in TradingView and Yahoo Finance
      final rsiValues = <double>[];
      final rsiTimestamps = <int>[]; // Timestamps for each RSI point
      final rsiPeriod = _rsiPeriod;

      if (closes.length < rsiPeriod + 1) {
        // Insufficient data
      } else {
        // Calculate initial average values (simple average)
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

        // Incremental calculation for remaining points using Wilder's formula
        for (int i = rsiPeriod + 1; i < closes.length; i++) {
          final change = closes[i] - closes[i - 1];
          final u = change > 0 ? change : 0.0;
          final d = change < 0 ? -change : 0.0;

          // Update using Wilder's formula: EMA = (prev * (n-1) + current) / n
          au = (au * (rsiPeriod - 1) + u) / rsiPeriod;
          ad = (ad * (rsiPeriod - 1) + d) / rsiPeriod;

          // Calculate RSI
          if (ad == 0) {
            rsiValues.add(100.0);
          } else {
            final rs = au / ad;
            final rsi = 100 - (100 / (1 + rs));
            rsiValues.add(rsi.clamp(0, 100));
          }

          // Save timestamp of corresponding candle
          rsiTimestamps.add(candles[i].timestamp);
        }
      }

      if (rsiValues.isEmpty && closes.length < 15) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                loc.t('home_insufficient_data',
                    params: {'count': '${candles.length}'}),
              ),
              duration: const Duration(seconds: 4),
            ),
          );
        }
      }

      // For chart display take only last N points
      // This improves readability, especially for large timeframes
      int maxChartPoints = 100; // Maximum points for chart
      if (_selectedTimeframe == '4h') {
        maxChartPoints = 60; // For 4h show last 60 points (~10 days)
      } else if (_selectedTimeframe == '1d') {
        maxChartPoints = 90; // For 1d show last 90 points (~3 months)
      } else if (_selectedTimeframe == '1h') {
        maxChartPoints = 100; // For 1h show last 100 points (~4 days)
      } else {
        maxChartPoints = 100; // For minute timeframes show last 100 points
      }

      // Take only last points for chart
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
      // Rollback symbol on error
      setState(() {
        _selectedSymbol = previousSymbol;
        _symbolController.text = previousSymbol;
      });
      // Detailed error logging
      debugPrint('Error loading RSI data:');
      debugPrint('Symbol: $_selectedSymbol');
      debugPrint('Timeframe: $_selectedTimeframe');
      debugPrint('Error: $e');
      debugPrint('Stack trace: $stackTrace');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              loc.t('home_instrument_not_found'),
            ),
            duration: const Duration(seconds: 5),
            action: SnackBarAction(
              label: loc.t('common_details'),
              onPressed: () {
                showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: Text(loc.t('home_error_details_title')),
                    content: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(loc.t('home_error_label_symbol',
                              params: {'symbol': _selectedSymbol})),
                          Text(loc.t('home_error_label_timeframe',
                              params: {'timeframe': _selectedTimeframe})),
                          const SizedBox(height: 8),
                          Text(
                            loc.t('home_error_label'),
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          Text('$e'),
                        ],
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: Text(loc.t('common_close')),
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
    final loc = context.loc;

    return Scaffold(
      appBar: AppBar(
        title: Text(loc.t('home_title')),
        backgroundColor: Colors.blue[900],
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.bookmark_border),
            tooltip: loc.t('home_watchlist_tooltip'),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => WatchlistScreen(isar: widget.isar),
                ),
              );
              // WatchlistScreen updates automatically when opened
            },
          ),
          IconButton(
            icon: const Icon(Icons.notifications),
            tooltip: loc.t('home_alerts_tooltip'),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => AlertsScreen(isar: widget.isar),
                ),
              );
              // Refresh alerts list after return
              _loadAlerts();
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: loc.t('home_settings_tooltip'),
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
                  // Remove focus when tapping on screen
                  FocusScope.of(context).unfocus();
                },
                behavior: HitTestBehavior.opaque,
                child: SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Symbol and timeframe selection
                      _buildSymbolSelector(),
                      const SizedBox(height: 16),

                      // RSI settings
                      _buildRsiSettingsCard(),
                      const SizedBox(height: 16),

                      // Current RSI
                      _buildCurrentRsiCard(),
                      const SizedBox(height: 16),

                      // RSI chart
                      _buildRsiChart(),
                      const SizedBox(height: 16),

                      // Active alerts
                      _buildActiveAlerts(),
                      const SizedBox(height: 16),

                      // Quick actions
                      _buildQuickActions(),
                    ],
                  ),
                ),
              ),
            ),
      floatingActionButton: FloatingActionButton(
        tooltip: loc.t('home_create_alert'),
        onPressed: () => _showCreateAlertDialog(),
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildSymbolSelector() {
    final loc = context.loc;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              loc.t('home_instrument_label'),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: Autocomplete<SymbolInfo>(
                    optionsBuilder: (TextEditingValue textEditingValue) async {
                      final query = textEditingValue.text.trim();

                      // If field is empty - show all popular symbols
                      if (query.isEmpty) {
                        // Reset loading flag if it was set
                        if (_isSearchingSymbols && mounted) {
                          setState(() {
                            _isSearchingSymbols = false;
                          });
                        }

                        // Show all popular symbols
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

                      // For single character also show popular symbols, but filtered
                      if (query.length == 1) {
                        if (_isSearchingSymbols && mounted) {
                          setState(() {
                            _isSearchingSymbols = false;
                          });
                        }
                        try {
                          final popularSymbols =
                              await _yahooService.fetchPopularSymbols();
                          // Filter by first character
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

                      // For search with 2+ characters
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
                        // Show all results, don't limit
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
                      // Sync controller with selected symbol only once during initialization
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
                          // When tapping on field, clear it to show popular list
                          // This allows quick instrument selection without having to erase text
                          if (textEditingController.text.isNotEmpty) {
                            textEditingController.clear();
                            _symbolController.clear();
                          }
                        },
                        onFieldSubmitted: (String value) {
                          // Allow direct symbol input even if it's not in the list
                          final trimmedValue = value.trim().toUpperCase();
                          if (trimmedValue.isNotEmpty &&
                              trimmedValue != _selectedSymbol) {
                            setState(() {
                              _selectedSymbol = trimmedValue;
                              _symbolController.text = trimmedValue;
                            });
                            _saveState();
                            _loadRsiData();
                          }
                          // Remove focus on submit
                          focusNode.unfocus();
                          onFieldSubmitted();
                        },
                        decoration: InputDecoration(
                          labelText: loc.t('home_symbol_label'),
                          hintText: loc.t('home_symbol_hint'),
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
                      // Update symbol and load data
                      // If loading fails, symbol will be rolled back in _loadRsiData
                      setState(() {
                        _selectedSymbol = selection.symbol;
                      });
                      _saveState();
                      _loadRsiData();
                      // Remove focus after selection
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
                  tooltip: loc.t('home_add_watchlist'),
                  onPressed: () => _addToWatchlist(_selectedSymbol),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _selectedTimeframe,
                    decoration: InputDecoration(
                      labelText: loc.t('home_timeframe_label'),
                      border: const OutlineInputBorder(),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 16),
                    ),
                    isExpanded: true,
                    style: const TextStyle(fontSize: 14),
                    items: const [
                      DropdownMenuItem(value: '1m', child: Text('1m')),
                      DropdownMenuItem(value: '5m', child: Text('5m')),
                      DropdownMenuItem(value: '15m', child: Text('15m')),
                      DropdownMenuItem(value: '1h', child: Text('1h')),
                      DropdownMenuItem(value: '4h', child: Text('4h')),
                      DropdownMenuItem(value: '1d', child: Text('1d')),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        setState(() {
                          _selectedTimeframe = value;
                        });
                        _saveState();
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
    final loc = context.loc;
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
                    loc.t('home_current_rsi_title',
                        params: {'symbol': _selectedSymbol}),
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
    final loc = context.loc;
    return Card(
      child: Padding(
        padding: const EdgeInsets.only(
            left: 4,
            right: 4,
            top: 16,
            bottom:
                16), // Minimum horizontal padding for maximum chart stretching
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                loc.t('home_rsi_chart_title'),
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 8),
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
    final loc = context.loc;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  loc.t('home_active_alerts_title'),
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold),
                ),
                TextButton(
                  onPressed: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => AlertsScreen(isar: widget.isar),
                      ),
                    );
                    // Refresh alerts list after return
                    _loadAlerts();
                  },
                  child: Text(loc.t('home_active_alerts_all')),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_alerts.isEmpty)
              Text(loc.t('home_no_active_alerts'))
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
    // Apply values from input fields
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

    // Clear input fields
    _clearControllers();

    // Recalculate RSI if period changed
    if (changed && period != null) {
      _loadRsiData();
    } else if (changed) {
      setState(() {}); // Update only levels
    }
  }

  void _resetRsiSettings() {
    setState(() {
      _rsiPeriod = 14;
      _lowerLevel = 30.0;
      _upperLevel = 70.0;
    });
    _saveState();
    _clearControllers();
    _loadRsiData();
  }

  Widget _buildRsiSettingsCard() {
    final loc = context.loc;
    return Card(
      child: Column(
        children: [
          InkWell(
            onTap: () {
              setState(() {
                _rsiSettingsExpanded = !_rsiSettingsExpanded;
                // When expanding, fill fields with current values
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
                  Text(
                    loc.t('home_rsi_settings_title'),
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold),
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
                          decoration: InputDecoration(
                            labelText: loc.t('home_rsi_period_label'),
                            border: const OutlineInputBorder(),
                            isDense: true,
                          ),
                          keyboardType: TextInputType.number,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: _lowerLevelController,
                          decoration: InputDecoration(
                            labelText: loc.t('home_lower_zone_label'),
                            border: const OutlineInputBorder(),
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
                          decoration: InputDecoration(
                            labelText: loc.t('home_upper_zone_label'),
                            border: const OutlineInputBorder(),
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
                        tooltip: loc.t('home_reset_defaults_tooltip'),
                        onPressed: _resetRsiSettings,
                        color: Colors.grey[600],
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.check, size: 20),
                        tooltip: loc.t('home_apply_changes_tooltip'),
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
    final loc = context.loc;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              loc.t('home_quick_actions_title'),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => _showCreateAlertDialog(),
                    icon: const Icon(Icons.add_alert),
                    label: Text(loc.t('home_create_alert')),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => _loadRsiData(),
                    icon: const Icon(Icons.refresh),
                    label: Text(loc.t('home_refresh')),
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
    // Always refresh alerts list after return
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
    // Always refresh alerts list after return
    _loadAlerts();
  }

  Future<void> _addToWatchlist(String symbol) async {
    final loc = context.loc;
    // Check if this symbol is already added
    final existing = await widget.isar.watchlistItems
        .where()
        .symbolEqualTo(symbol)
        .findFirst();

    if (existing != null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              loc.t('home_watchlist_exists', params: {'symbol': symbol}),
            ),
          ),
        );
      }
      return;
    }

    // Add to watchlist
    // First get all existing items to ensure ID is assigned correctly
    final allExistingItems = await widget.isar.watchlistItems.where().findAll();
    debugPrint(
        'HomeScreen: Before adding $symbol there are ${allExistingItems.length} items');
    if (allExistingItems.isNotEmpty) {
      debugPrint(
          'HomeScreen: Existing items: ${allExistingItems.map((e) => '${e.symbol} (id:${e.id})').toList()}');
    }

    // Calculate next available ID
    int nextId = 1;
    if (allExistingItems.isNotEmpty) {
      final maxId =
          allExistingItems.map((e) => e.id).reduce((a, b) => a > b ? a : b);
      nextId = maxId + 1;
    }
    debugPrint('HomeScreen: Next available ID: $nextId');

    // Create new item with explicit ID
    final item = WatchlistItem();
    item.id = nextId; // Explicitly set ID
    item.symbol = symbol;
    item.createdAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    await widget.isar.writeTxn(() {
      // Use put() with explicit ID
      return widget.isar.watchlistItems.put(item);
    });

    debugPrint('HomeScreen: After put() item.id = ${item.id}');

    // Verify that item was actually added
    final allItems = await widget.isar.watchlistItems.where().findAll();
    debugPrint(
        'HomeScreen: After adding $symbol total items: ${allItems.length}');
    debugPrint(
        'HomeScreen: Symbols in watchlist: ${allItems.map((e) => '${e.symbol} (id:${e.id})').toList()}');

    // Verify that new item actually has unique ID
    final addedItem = await widget.isar.watchlistItems
        .where()
        .symbolEqualTo(symbol)
        .findAll();
    debugPrint(
        'HomeScreen: Found items with symbol $symbol: ${addedItem.length}');
    if (addedItem.length > 1) {
      debugPrint(
          'HomeScreen: WARNING! Duplicates for $symbol: ${addedItem.map((e) => e.id).toList()}');
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            loc.t('home_watchlist_added', params: {'symbol': symbol}),
          ),
        ),
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
