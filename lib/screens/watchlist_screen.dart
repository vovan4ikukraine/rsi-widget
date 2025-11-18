import 'dart:async';
import 'package:flutter/material.dart';
import 'package:isar/isar.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models.dart';
import '../services/yahoo_proto.dart';
import '../services/widget_service.dart';
import '../widgets/rsi_chart.dart';
import '../localization/app_localizations.dart';
import '../services/data_sync_service.dart';
import '../services/auth_service.dart';

class WatchlistScreen extends StatefulWidget {
  final Isar isar;

  const WatchlistScreen({super.key, required this.isar});

  @override
  State<WatchlistScreen> createState() => _WatchlistScreenState();
}

enum _RsiSortOrder { none, descending, ascending }

class _WatchlistScreenState extends State<WatchlistScreen>
    with WidgetsBindingObserver {
  final YahooProtoSource _yahooService =
      YahooProtoSource('https://rsi-workers.vovan4ikukraine.workers.dev');
  late final WidgetService _widgetService;

  static const String _sortOrderPrefKey = 'watchlist_sort_order';

  List<WatchlistItem> _watchlistItems = [];
  final Map<String, _SymbolRsiData> _rsiDataMap = {};
  bool _isLoading = false;
  bool _settingsExpanded = false;
  bool _isActionInProgress = false;
  _RsiSortOrder _currentSortOrder = _RsiSortOrder.none;

  // Settings for all charts
  String _timeframe = '15m';
  int _rsiPeriod = 14;
  double _lowerLevel = 30.0;
  double _upperLevel = 70.0;

  // Controllers for settings input fields
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

  Future<void> _updateWidgetOrder(bool sortDescending) async {
    try {
      await _widgetService.updateWidget(
        timeframe: _timeframe,
        rsiPeriod: _rsiPeriod,
        sortDescending: sortDescending,
      );
    } catch (e, stackTrace) {
      debugPrint(
          'WatchlistScreen: Failed to update widget order: $e\n$stackTrace');
    }
  }

  String _sortOrderToString(_RsiSortOrder order) {
    switch (order) {
      case _RsiSortOrder.ascending:
        return 'ascending';
      case _RsiSortOrder.descending:
        return 'descending';
      case _RsiSortOrder.none:
        return 'none';
    }
  }

  _RsiSortOrder _sortOrderFromString(String? value) {
    switch (value) {
      case 'ascending':
        return _RsiSortOrder.ascending;
      case 'descending':
        return _RsiSortOrder.descending;
      default:
        return _RsiSortOrder.none;
    }
  }

  Future<void> _saveSortOrderPreference(_RsiSortOrder order) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_sortOrderPrefKey, _sortOrderToString(order));
    } catch (e, stackTrace) {
      debugPrint('WatchlistScreen: Failed to save sort order: $e\n$stackTrace');
    }
  }

  void _applySortOrder(
    _RsiSortOrder order, {
    bool persistPreference = false,
    bool notifyWidget = false,
  }) {
    if (!mounted) {
      _currentSortOrder = order;
      if (persistPreference) {
        unawaited(_saveSortOrderPreference(order));
      }
      if (notifyWidget) {
        unawaited(
          _updateWidgetOrder(order == _RsiSortOrder.descending),
        );
      }
      return;
    }

    if (_watchlistItems.isEmpty) {
      setState(() {
        _currentSortOrder = order;
      });
      if (persistPreference) {
        unawaited(_saveSortOrderPreference(order));
      }
      if (notifyWidget) {
        unawaited(
          _updateWidgetOrder(order == _RsiSortOrder.descending),
        );
      }
      return;
    }

    if (order == _RsiSortOrder.none) {
      setState(() {
        _currentSortOrder = order;
      });
      if (persistPreference) {
        unawaited(_saveSortOrderPreference(order));
      }
      if (notifyWidget) {
        unawaited(_updateWidgetOrder(true));
      }
      return;
    }

    final originalPositions = <String, int>{};
    for (var i = 0; i < _watchlistItems.length; i++) {
      originalPositions[_watchlistItems[i].symbol] = i;
    }

    double valueForSymbol(String symbol) {
      final value = _rsiDataMap[symbol]?.rsi;
      if (value == null) {
        return order == _RsiSortOrder.descending
            ? double.negativeInfinity
            : double.infinity;
      }
      return value;
    }

    final sortedItems = List<WatchlistItem>.from(_watchlistItems);
    sortedItems.sort((a, b) {
      final rsiA = valueForSymbol(a.symbol);
      final rsiB = valueForSymbol(b.symbol);
      final comparison = order == _RsiSortOrder.descending
          ? rsiB.compareTo(rsiA)
          : rsiA.compareTo(rsiB);
      if (comparison != 0) return comparison;
      final posA = originalPositions[a.symbol] ?? 0;
      final posB = originalPositions[b.symbol] ?? 0;
      return posA.compareTo(posB);
    });

    setState(() {
      _watchlistItems = sortedItems;
      _currentSortOrder = order;
    });

    if (persistPreference) {
      unawaited(_saveSortOrderPreference(order));
    }
    if (notifyWidget) {
      unawaited(
        _updateWidgetOrder(order == _RsiSortOrder.descending),
      );
    }
  }

  Future<void> _loadSavedState() async {
    final prefs = await SharedPreferences.getInstance();

    // Load widget period first (if it was set), then fallback to watchlist period
    final widgetPeriod = prefs.getInt('rsi_widget_period');
    final watchlistPeriod = prefs.getInt('watchlist_rsi_period');
    final widgetTimeframe = prefs.getString('rsi_widget_timeframe');
    final watchlistTimeframe = prefs.getString('watchlist_timeframe');

    setState(() {
      // Use widget settings if available, otherwise use watchlist settings
      _timeframe = widgetTimeframe ?? watchlistTimeframe ?? '15m';
      _rsiPeriod = widgetPeriod ?? watchlistPeriod ?? 14;
      _lowerLevel = prefs.getDouble('watchlist_lower_level') ?? 30.0;
      _upperLevel = prefs.getDouble('watchlist_upper_level') ?? 70.0;
      _currentSortOrder =
          _sortOrderFromString(prefs.getString(_sortOrderPrefKey));
    });

    // Save period and timeframe for widget to ensure consistency
    await prefs.setInt('rsi_widget_period', _rsiPeriod);
    await prefs.setString('rsi_widget_timeframe', _timeframe);
    // Also save to watchlist settings for consistency
    await prefs.setInt('watchlist_rsi_period', _rsiPeriod);
    await prefs.setString('watchlist_timeframe', _timeframe);

    _loadWatchlist();
  }

  Future<void> _saveState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('watchlist_timeframe', _timeframe);
    await prefs.setInt('watchlist_rsi_period', _rsiPeriod);
    await prefs.setDouble('watchlist_lower_level', _lowerLevel);
    await prefs.setDouble('watchlist_upper_level', _upperLevel);
    // Also save to widget settings to keep them in sync
    await prefs.setInt('rsi_widget_period', _rsiPeriod);
    await prefs.setString('rsi_widget_timeframe', _timeframe);
  }

  // Reload list when app returns from background
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadWatchlist();
      // Check if timeframe changed in widget and update data
      _checkWidgetTimeframe();
    }
  }

  Future<void> _checkWidgetTimeframe() async {
    // Load timeframe and period from widget (if changed in widget)
    final prefs = await SharedPreferences.getInstance();
    final widgetTimeframe = prefs.getString('rsi_widget_timeframe');
    final widgetPeriod = prefs.getInt('rsi_widget_period');
    final widgetNeedsRefresh = prefs.getBool('widget_needs_refresh') ?? false;

    bool needsUpdate = false;

    // If timeframe changed in widget, update it in app
    if (widgetTimeframe != null && widgetTimeframe != _timeframe) {
      setState(() {
        _timeframe = widgetTimeframe;
      });
      _saveState();
      needsUpdate = true;
    }

    // If period changed in widget, update it in app
    if (widgetPeriod != null && widgetPeriod != _rsiPeriod) {
      setState(() {
        _rsiPeriod = widgetPeriod;
      });
      _saveState();
      needsUpdate = true;
    }

    // If widget requested update or something changed, reload data
    if (needsUpdate || widgetNeedsRefresh) {
      // Reset update flag
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
      // Fetch watchlist from server if authenticated
      if (AuthService.isSignedIn) {
        await DataSyncService.fetchWatchlist(widget.isar);
      } else {
        // In anonymous mode, restore from cache if database is empty
        final existingItems =
            await widget.isar.watchlistItems.where().findAll();
        if (existingItems.isEmpty) {
          await DataSyncService.restoreWatchlistFromCache(widget.isar);
        }
      }

      // Load all items from database
      final items = await widget.isar.watchlistItems.where().findAll();
      debugPrint('WatchlistScreen: Loaded ${items.length} items from database');

      if (items.isEmpty) {
        debugPrint('WatchlistScreen: Database is empty!');
        setState(() {
          _watchlistItems = [];
          _rsiDataMap.clear();
        });
        return;
      }

      debugPrint(
          'WatchlistScreen: Symbols: ${items.map((e) => '${e.symbol} (id:${e.id}, createdAt:${e.createdAt})').toList()}');

      // Sort by creation date (oldest first, newest last)
      final sortedItems = List<WatchlistItem>.from(items);
      sortedItems.sort((a, b) => a.createdAt.compareTo(b.createdAt));

      debugPrint(
          'WatchlistScreen: After sorting: ${sortedItems.map((e) => e.symbol).toList()}');

      setState(() {
        _watchlistItems = sortedItems;
        debugPrint(
            'WatchlistScreen: After setState _watchlistItems.length = ${_watchlistItems.length}');
        debugPrint(
            'WatchlistScreen: _watchlistItems contains: ${_watchlistItems.map((e) => e.symbol).toList()}');
      });

      if (_currentSortOrder != _RsiSortOrder.none) {
        _applySortOrder(
          _currentSortOrder,
          persistPreference: false,
          notifyWidget: false,
        );
      }

      // Load RSI data for all symbols
      await _loadAllRsiData();
      // Update widget after loading watchlist (use current watchlist settings)
      unawaited(_widgetService.updateWidget(
        timeframe: _timeframe,
        rsiPeriod: _rsiPeriod,
        sortDescending: _currentSortOrder != _RsiSortOrder.ascending,
      ));
    } catch (e, stackTrace) {
      debugPrint('WatchlistScreen: Error loading list: $e');
      debugPrint('WatchlistScreen: Stack trace: $stackTrace');
      if (mounted) {
        final loc = context.loc;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              loc.t('watchlist_error_loading', params: {'message': '$e'}),
            ),
          ),
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
      // Load data with limited parallelism (max 8 concurrent requests)
      // This prevents overwhelming the server while still being faster than sequential
      // Increased from 5 to 8 as client-side cache reduces actual HTTP requests
      const maxConcurrent = 8;
      final symbols = _watchlistItems.map((item) => item.symbol).toList();

      for (int i = 0; i < symbols.length; i += maxConcurrent) {
        final batch = symbols.skip(i).take(maxConcurrent).toList();
        await Future.wait(
          batch.map((symbol) => _loadRsiDataForSymbol(symbol)),
          eagerError: false, // Continue even if some fail
        );
      }
    } finally {
      if (_currentSortOrder != _RsiSortOrder.none) {
        _applySortOrder(
          _currentSortOrder,
          persistPreference: false,
          notifyWidget: false,
        );
      }
      setState(() {
        _isLoading = false;
      });
      // Update widget after loading data (use current watchlist settings)
      unawaited(_widgetService.updateWidget(
        timeframe: _timeframe,
        rsiPeriod: _rsiPeriod,
        sortDescending: _currentSortOrder != _RsiSortOrder.ascending,
      ));
    }
  }

  Future<void> _loadRsiDataForSymbol(String symbol) async {
    const maxRetries = 3;
    int attempt = 0;

    while (attempt < maxRetries) {
      try {
        // Determine limit depending on timeframe
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

        // RSI calculation using Wilder's algorithm
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

        // Take only last 50 points for compact chart
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
        return; // Success, exit retry loop
      } catch (e) {
        attempt++;
        debugPrint(
            'Error loading RSI for $symbol (attempt $attempt/$maxRetries): $e');

        if (attempt >= maxRetries) {
          // All retries failed, set empty data
          debugPrint(
              'Failed to load RSI for $symbol after $maxRetries attempts');
          setState(() {
            _rsiDataMap[symbol] = _SymbolRsiData(
              rsi: 0.0,
              rsiValues: [],
              timestamps: [],
            );
          });
        } else {
          // Wait before retry with exponential backoff (1s, 2s, 4s)
          final delayMs = 1000 * (1 << (attempt - 1));
          await Future.delayed(Duration(milliseconds: delayMs));
        }
      }
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
    // Sync watchlist: to server if authenticated, to cache if anonymous
    if (AuthService.isSignedIn) {
      unawaited(DataSyncService.syncWatchlist(widget.isar));
    } else {
      unawaited(DataSyncService.saveWatchlistToCache(widget.isar));
    }
    // Update widget after deletion
    unawaited(_widgetService.updateWidget(
      timeframe: _timeframe,
      rsiPeriod: _rsiPeriod,
      sortDescending: _currentSortOrder != _RsiSortOrder.ascending,
    ));
  }

  Future<void> _applySettings() async {
    if (_isLoading || _isActionInProgress) return;
    if (mounted) {
      setState(() {
        _isActionInProgress = true;
      });
    } else {
      _isActionInProgress = true;
    }

    try {
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
        // Save period for widget
        if (period != null) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setInt('rsi_widget_period', _rsiPeriod);
        }
        _loadAllRsiData();
        // Update widget with new period
        unawaited(_widgetService.updateWidget(
          rsiPeriod: _rsiPeriod,
          sortDescending: _currentSortOrder != _RsiSortOrder.ascending,
        ));
      } else {
        if (mounted) {
          setState(() {});
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _isActionInProgress = false;
        });
      } else {
        _isActionInProgress = false;
      }
    }
  }

  Future<void> _resetSettings() async {
    if (_isLoading || _isActionInProgress) return;
    if (mounted) {
      setState(() {
        _isActionInProgress = true;
      });
    } else {
      _isActionInProgress = true;
    }

    try {
      setState(() {
        _timeframe = '15m';
        _rsiPeriod = 14;
        _lowerLevel = 30.0;
        _upperLevel = 70.0;
      });
      _saveState();
      // Save period for widget
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('rsi_widget_period', _rsiPeriod);
      _updateControllerHints();
      _loadAllRsiData();
      // Update widget
      unawaited(_widgetService.updateWidget(
        timeframe: _timeframe,
        rsiPeriod: _rsiPeriod,
        sortDescending: _currentSortOrder != _RsiSortOrder.ascending,
      ));
    } finally {
      if (mounted) {
        setState(() {
          _isActionInProgress = false;
        });
      } else {
        _isActionInProgress = false;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    return Scaffold(
      appBar: AppBar(
        title: Text(loc.t('watchlist_title')),
        backgroundColor: Colors.blue[900],
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          // Collapsible settings bar
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                InkWell(
                  onTap: () {
                    setState(() {
                      _settingsExpanded = !_settingsExpanded;
                      // When expanding, fill fields with current values
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
                        Text(
                          loc.t('watchlist_settings_title'),
                          style: const TextStyle(
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
                                decoration: InputDecoration(
                                  labelText: loc.t('home_timeframe_label'),
                                  border: const OutlineInputBorder(),
                                  isDense: true,
                                  contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 8),
                                ),
                                isExpanded: true,
                                items: const [
                                  DropdownMenuItem(
                                      value: '1m', child: Text('1m')),
                                  DropdownMenuItem(
                                      value: '5m', child: Text('5m')),
                                  DropdownMenuItem(
                                      value: '15m', child: Text('15m')),
                                  DropdownMenuItem(
                                      value: '1h', child: Text('1h')),
                                  DropdownMenuItem(
                                      value: '4h', child: Text('4h')),
                                  DropdownMenuItem(
                                      value: '1d', child: Text('1d')),
                                ],
                                onChanged: (value) async {
                                  if (value != null) {
                                    setState(() {
                                      _timeframe = value;
                                    });
                                    _saveState();
                                    // Save timeframe for widget
                                    final prefs =
                                        await SharedPreferences.getInstance();
                                    await prefs.setString(
                                        'rsi_widget_timeframe', _timeframe);
                                    await prefs.setInt(
                                        'rsi_widget_period', _rsiPeriod);
                                    _loadAllRsiData(); // Automatically reload data when timeframe changes
                                    // Update widget
                                    unawaited(_widgetService.updateWidget(
                                      timeframe: _timeframe,
                                      rsiPeriod: _rsiPeriod,
                                      sortDescending: _currentSortOrder !=
                                          _RsiSortOrder.ascending,
                                    ));
                                  }
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextField(
                                controller: _rsiPeriodController,
                                decoration: InputDecoration(
                                  labelText: loc.t('home_rsi_period_label'),
                                  border: const OutlineInputBorder(),
                                  isDense: true,
                                  contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 8),
                                ),
                                keyboardType: TextInputType.number,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextField(
                                controller: _lowerLevelController,
                                decoration: InputDecoration(
                                  labelText: loc.t('home_lower_zone_label'),
                                  border: const OutlineInputBorder(),
                                  isDense: true,
                                  contentPadding: const EdgeInsets.symmetric(
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
                                decoration: InputDecoration(
                                  labelText: loc.t('home_upper_zone_label'),
                                  border: const OutlineInputBorder(),
                                  isDense: true,
                                  contentPadding: const EdgeInsets.symmetric(
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
                          children: [
                            IconButton(
                              icon: Icon(
                                () {
                                  switch (_currentSortOrder) {
                                    case _RsiSortOrder.descending:
                                      return Icons.north;
                                    case _RsiSortOrder.ascending:
                                      return Icons.south;
                                    case _RsiSortOrder.none:
                                      return Icons.unfold_more;
                                  }
                                }(),
                                color: () {
                                  switch (_currentSortOrder) {
                                    case _RsiSortOrder.descending:
                                      return Colors.green;
                                    case _RsiSortOrder.ascending:
                                      return Colors.red;
                                    case _RsiSortOrder.none:
                                      return Colors.grey[600];
                                  }
                                }(),
                              ),
                              tooltip: () {
                                switch (_currentSortOrder) {
                                  case _RsiSortOrder.descending:
                                    return loc.t('watchlist_sort_desc');
                                  case _RsiSortOrder.ascending:
                                    return loc.t('watchlist_sort_asc');
                                  case _RsiSortOrder.none:
                                    return loc.t('watchlist_sort_desc');
                                }
                              }(),
                              onPressed: (_isLoading || _isActionInProgress)
                                  ? null
                                  : () {
                                      if (_watchlistItems.isEmpty) return;
                                      final targetOrder = _currentSortOrder ==
                                              _RsiSortOrder.descending
                                          ? _RsiSortOrder.ascending
                                          : _RsiSortOrder.descending;
                                      _applySortOrder(
                                        targetOrder,
                                        persistPreference: true,
                                        notifyWidget: true,
                                      );
                                    },
                            ),
                            const Spacer(),
                            const SizedBox(width: 8),
                            IconButton(
                              icon: const Icon(Icons.refresh, size: 18),
                              tooltip: loc.t('watchlist_reset'),
                              onPressed: (_isLoading || _isActionInProgress)
                                  ? null
                                  : _resetSettings,
                              color: Colors.blue,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                            ),
                            const SizedBox(width: 8),
                            IconButton(
                              icon: const Icon(Icons.check, size: 18),
                              tooltip: loc.t('watchlist_apply'),
                              onPressed: (_isLoading || _isActionInProgress)
                                  ? null
                                  : _applySettings,
                              color: Colors.green,
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
          // Instruments list
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
                              loc.t('watchlist_empty_title'),
                              style: TextStyle(
                                  color: Colors.grey[400], fontSize: 18),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              loc.t('watchlist_empty_subtitle'),
                              style: TextStyle(
                                  color: Colors.grey[600], fontSize: 14),
                            ),
                          ],
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: () async {
                          await _loadWatchlist(); // Reload entire list, not just RSI data
                        },
                        child: _watchlistItems.isEmpty
                            ? Center(child: Text(loc.t('watchlist_no_items')))
                            : Builder(
                                builder: (context) {
                                  debugPrint(
                                      'WatchlistScreen: ListView.builder will display ${_watchlistItems.length} items');
                                  return ListView.builder(
                                    key: ValueKey(
                                        'watchlist_${_watchlistItems.length}'), // Key for forced update
                                    padding:
                                        const EdgeInsets.symmetric(vertical: 8),
                                    itemCount: _watchlistItems.length,
                                    itemBuilder: (context, index) {
                                      if (index >= _watchlistItems.length) {
                                        debugPrint(
                                            'WatchlistScreen: ERROR! Index $index >= list length ${_watchlistItems.length}');
                                        return const SizedBox.shrink();
                                      }

                                      final item = _watchlistItems[index];
                                      debugPrint(
                                          'WatchlistScreen: Displaying item $index: ${item.symbol} (id: ${item.id})');

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
    final loc = context.loc;
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
              title: Text(loc.t('watchlist_remove_title')),
              content: Text(
                loc.t('watchlist_remove_message',
                    params: {'symbol': item.symbol}),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(loc.t('common_cancel')),
                ),
                ElevatedButton(
                  onPressed: () {
                    Navigator.pop(context);
                    _removeFromWatchlist(item);
                  },
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                  child: Text(loc.t('watchlist_remove')),
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
                      fontSize: 14, // Reduced font size from 16 to 14
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    loc.t('watchlist_rsi_prefix',
                        params: {'value': rsi.toStringAsFixed(1)}),
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
                  height: 53, // Increased from 50 to 53 (approximately 5%)
                  child: RsiChart(
                    rsiValues: rsiData.rsiValues,
                    timestamps: rsiData.timestamps,
                    symbol: item.symbol,
                    timeframe: _timeframe,
                    levels: [_lowerLevel, _upperLevel],
                    showGrid: false,
                    showLabels: true, // Enable labels for Y axis
                    lineWidth: 1.2,
                    isInteractive: false, // But tooltip will still work
                  ),
                )
              else
                SizedBox(
                  height: 53, // Increased from 50 to 53 (approximately 5%)
                  child: Center(
                    child: Text(
                      loc.t('watchlist_no_data'),
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
