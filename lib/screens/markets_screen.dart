import 'dart:async';
import 'package:flutter/material.dart';
import 'package:isar/isar.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/indicator_type.dart';
import '../models.dart';
import '../services/yahoo_proto.dart';
import '../services/indicator_service.dart';
import '../widgets/indicator_chart.dart';
import '../localization/app_localizations.dart';
import '../data/popular_symbols.dart';
import '../state/app_state.dart';
import '../widgets/indicator_selector.dart';

class MarketsScreen extends StatefulWidget {
  final Isar isar;

  const MarketsScreen({super.key, required this.isar});

  @override
  State<MarketsScreen> createState() => _MarketsScreenState();
}

class _MarketsScreenState extends State<MarketsScreen>
    with SingleTickerProviderStateMixin {
  final YahooProtoSource _yahooService = YahooProtoSource(
    'https://rsi-workers.vovan4ikukraine.workers.dev',
  );
  late TabController _tabController;
  AppState? _appState;

  // Settings for all charts
  String _timeframe = '15m';
  int _indicatorPeriod = 14;
  double _lowerLevel = 30.0;
  double _upperLevel = 70.0;
  IndicatorType? _previousIndicatorType; // Track previous indicator to save its settings
  int? _stochDPeriod;
  bool _settingsExpanded = false;

  // Controllers for settings input fields
  final TextEditingController _indicatorPeriodController =
      TextEditingController();
  final TextEditingController _lowerLevelController = TextEditingController();
  final TextEditingController _upperLevelController = TextEditingController();
  final TextEditingController _stochDPeriodController = TextEditingController();

  // Data for each category
  List<SymbolInfo> _cryptoSymbols = [];
  List<SymbolInfo> _indexSymbols = [];
  List<SymbolInfo> _forexSymbols = [];
  List<SymbolInfo> _commoditySymbols = [];

  // Indicator data map: symbol -> indicator data
  final Map<String, _SymbolIndicatorData> _indicatorDataMap = {};
  // Track which symbols are currently being loaded
  final Set<String> _loadingSymbols = {};
  // Track which symbols have been loaded at least once (for cache check)
  final Set<String> _loadedSymbols = {};
  bool _isLoading = false;

  // Scroll controllers for each tab to detect visible items
  final Map<int, ScrollController> _scrollControllers = {};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    // Create scroll controllers for each tab
    for (int i = 0; i < 4; i++) {
      _scrollControllers[i] = ScrollController();
    }
    _tabController.addListener(_onTabChanged);
    _loadSymbols();
    _loadSavedState();
  }

  void _onTabChanged() {
    if (_tabController.indexIsChanging) {
      // Load first batch of items when switching tabs
      _loadVisibleItems();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _appState = AppStateScope.of(context);
    _previousIndicatorType = _appState?.selectedIndicator;
    _appState?.addListener(_onIndicatorChanged);
    // Update controllers if app state is available and we haven't loaded yet
    if (_appState != null && _indicatorPeriodController.text.isEmpty) {
      final indicatorType = _appState!.selectedIndicator;
      setState(() {
        _indicatorPeriod = indicatorType.defaultPeriod;
        _lowerLevel = indicatorType.defaultLevels.first;
        _upperLevel = indicatorType.defaultLevels.length > 1
            ? indicatorType.defaultLevels[1]
            : 100.0;
        if (indicatorType == IndicatorType.stoch) {
          _stochDPeriod = 3;
        }
        // Update controllers
        _indicatorPeriodController.text = _indicatorPeriod.toString();
        _lowerLevelController.text = _lowerLevel.toStringAsFixed(1);
        _upperLevelController.text = _upperLevel.toStringAsFixed(1);
        if (_stochDPeriod != null) {
          _stochDPeriodController.text = _stochDPeriod.toString();
        }
      });
    }
  }

  void _onIndicatorChanged() async {
    if (_appState != null) {
      final prefs = await SharedPreferences.getInstance();
      final indicatorType = _appState!.selectedIndicator;
      
      // Save current settings for the PREVIOUS indicator before switching
      if (_previousIndicatorType != null && _previousIndicatorType != indicatorType) {
        await prefs.setInt(
          'markets_${_previousIndicatorType!.toJson()}_period',
          _indicatorPeriod,
        );
        await prefs.setDouble(
          'markets_${_previousIndicatorType!.toJson()}_lower_level',
          _lowerLevel,
        );
        await prefs.setDouble(
          'markets_${_previousIndicatorType!.toJson()}_upper_level',
          _upperLevel,
        );
        if (_previousIndicatorType == IndicatorType.stoch && _stochDPeriod != null) {
          await prefs.setInt('markets_stoch_d_period', _stochDPeriod!);
        }
      }

      // Load saved settings for the new indicator, or use defaults
      // IMPORTANT: Always use defaults if no saved settings exist, don't use current values
      final savedPeriod = prefs.getInt('markets_${indicatorType.toJson()}_period');
      final savedLowerLevel = prefs.getDouble('markets_${indicatorType.toJson()}_lower_level');
      final savedUpperLevel = prefs.getDouble('markets_${indicatorType.toJson()}_upper_level');
      
      // Check if saved values are in valid range for this indicator
      final savedLowerValid = savedLowerLevel != null &&
          ((indicatorType == IndicatorType.williams && savedLowerLevel >= -100.0 && savedLowerLevel <= 0.0) ||
           (indicatorType != IndicatorType.williams && savedLowerLevel >= 0.0 && savedLowerLevel <= 100.0));
      final savedUpperValid = savedUpperLevel != null &&
          ((indicatorType == IndicatorType.williams && savedUpperLevel >= -100.0 && savedUpperLevel <= 0.0) ||
           (indicatorType != IndicatorType.williams && savedUpperLevel >= 0.0 && savedUpperLevel <= 100.0));
      
      setState(() {
        // Only use saved values if they exist and are valid for this indicator, otherwise use defaults
        _indicatorPeriod = savedPeriod ?? indicatorType.defaultPeriod;
        _lowerLevel = savedLowerValid ? savedLowerLevel : indicatorType.defaultLevels.first;
        _upperLevel = savedUpperValid ? savedUpperLevel :
            (indicatorType.defaultLevels.length > 1
                ? indicatorType.defaultLevels[1]
                : 100.0);

        // For Stochastic, load saved %D period or use default
        if (indicatorType == IndicatorType.stoch) {
          _stochDPeriod = prefs.getInt('markets_stoch_d_period') ?? 3;
        } else {
          _stochDPeriod = null;
        }

        // Update controllers
        _indicatorPeriodController.text = _indicatorPeriod.toString();
        _lowerLevelController.text = _lowerLevel.toStringAsFixed(1);
        _upperLevelController.text = _upperLevel.toStringAsFixed(1);
        if (_stochDPeriod != null) {
          _stochDPeriodController.text = _stochDPeriod.toString();
        } else {
          _stochDPeriodController.clear();
        }
      });

      // Update previous indicator type AFTER loading new settings
      _previousIndicatorType = indicatorType;

      // Save loaded settings so they persist for next time
      await _saveState();

      // Clear cache and reload visible items when indicator changes
      _loadedSymbols.clear();
      _indicatorDataMap.clear();
      unawaited(_loadVisibleItems());
    }
  }

  @override
  void dispose() {
    _appState?.removeListener(_onIndicatorChanged);
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    for (final controller in _scrollControllers.values) {
      controller.dispose();
    }
    _indicatorPeriodController.dispose();
    _lowerLevelController.dispose();
    _upperLevelController.dispose();
    _stochDPeriodController.dispose();
    super.dispose();
  }

  void _loadSymbols() {
    // Load symbols from popular_symbols.dart and categorize them
    final allSymbols = popularSymbols;

    // Crypto: top 100 by market cap (we'll use all available crypto for now)
    _cryptoSymbols =
        allSymbols.where((s) => s.type == 'crypto').take(100).toList();

    // Indexes: top 10
    _indexSymbols =
        allSymbols.where((s) => s.type == 'index').take(10).toList();

    // Forex: top 20 most popular pairs
    _forexSymbols =
        allSymbols.where((s) => s.type == 'currency').take(20).toList();

    // Commodities: top 20 (will need to add more symbols to popular_symbols)
    // For now, use a hardcoded list of popular commodities
    _commoditySymbols = [
      SymbolInfo(
        symbol: 'GC=F',
        name: 'Gold Futures',
        type: 'commodity',
        currency: 'USD',
        exchange: 'COMEX',
      ),
      SymbolInfo(
        symbol: 'SI=F',
        name: 'Silver Futures',
        type: 'commodity',
        currency: 'USD',
        exchange: 'COMEX',
      ),
      SymbolInfo(
        symbol: 'CL=F',
        name: 'Crude Oil Futures',
        type: 'commodity',
        currency: 'USD',
        exchange: 'NYMEX',
      ),
      SymbolInfo(
        symbol: 'NG=F',
        name: 'Natural Gas Futures',
        type: 'commodity',
        currency: 'USD',
        exchange: 'NYMEX',
      ),
      SymbolInfo(
        symbol: 'HG=F',
        name: 'Copper Futures',
        type: 'commodity',
        currency: 'USD',
        exchange: 'COMEX',
      ),
      SymbolInfo(
        symbol: 'ZC=F',
        name: 'Corn Futures',
        type: 'commodity',
        currency: 'USD',
        exchange: 'CBOT',
      ),
      SymbolInfo(
        symbol: 'ZS=F',
        name: 'Soybean Futures',
        type: 'commodity',
        currency: 'USD',
        exchange: 'CBOT',
      ),
      SymbolInfo(
        symbol: 'ZW=F',
        name: 'Wheat Futures',
        type: 'commodity',
        currency: 'USD',
        exchange: 'CBOT',
      ),
      SymbolInfo(
        symbol: 'KC=F',
        name: 'Coffee Futures',
        type: 'commodity',
        currency: 'USD',
        exchange: 'ICE',
      ),
      SymbolInfo(
        symbol: 'SB=F',
        name: 'Sugar Futures',
        type: 'commodity',
        currency: 'USD',
        exchange: 'ICE',
      ),
      SymbolInfo(
        symbol: 'CT=F',
        name: 'Cotton Futures',
        type: 'commodity',
        currency: 'USD',
        exchange: 'ICE',
      ),
      SymbolInfo(
        symbol: 'CC=F',
        name: 'Cocoa Futures',
        type: 'commodity',
        currency: 'USD',
        exchange: 'ICE',
      ),
      SymbolInfo(
        symbol: 'LBS=F',
        name: 'Lumber Futures',
        type: 'commodity',
        currency: 'USD',
        exchange: 'CME',
      ),
      SymbolInfo(
        symbol: 'PL=F',
        name: 'Platinum Futures',
        type: 'commodity',
        currency: 'USD',
        exchange: 'NYMEX',
      ),
      SymbolInfo(
        symbol: 'PA=F',
        name: 'Palladium Futures',
        type: 'commodity',
        currency: 'USD',
        exchange: 'NYMEX',
      ),
      SymbolInfo(
        symbol: 'RB=F',
        name: 'RBOB Gasoline Futures',
        type: 'commodity',
        currency: 'USD',
        exchange: 'NYMEX',
      ),
      SymbolInfo(
        symbol: 'HO=F',
        name: 'Heating Oil Futures',
        type: 'commodity',
        currency: 'USD',
        exchange: 'NYMEX',
      ),
      SymbolInfo(
        symbol: 'BZ=F',
        name: 'Brent Crude Futures',
        type: 'commodity',
        currency: 'USD',
        exchange: 'ICE',
      ),
      SymbolInfo(
        symbol: 'ZO=F',
        name: 'Oats Futures',
        type: 'commodity',
        currency: 'USD',
        exchange: 'CBOT',
      ),
      SymbolInfo(
        symbol: 'ZL=F',
        name: 'Soybean Oil Futures',
        type: 'commodity',
        currency: 'USD',
        exchange: 'CBOT',
      ),
    ].take(20).toList();

    // Load first batch of indicator data (lazy loading)
    unawaited(_loadVisibleItems());
  }

  Future<void> _loadSavedState() async {
    final prefs = await SharedPreferences.getInstance();
    final indicatorType = _appState?.selectedIndicator ?? IndicatorType.rsi;
    setState(() {
      _timeframe = prefs.getString('markets_timeframe') ?? '15m';
      _indicatorPeriod =
          prefs.getInt('markets_${indicatorType.toJson()}_period') ??
              indicatorType.defaultPeriod;
      _lowerLevel =
          prefs.getDouble('markets_${indicatorType.toJson()}_lower_level') ??
              indicatorType.defaultLevels.first;
      _upperLevel =
          prefs.getDouble('markets_${indicatorType.toJson()}_upper_level') ??
              (indicatorType.defaultLevels.length > 1
                  ? indicatorType.defaultLevels[1]
                  : 100.0);
      if (indicatorType == IndicatorType.stoch) {
        _stochDPeriod = prefs.getInt('markets_stoch_d_period') ?? 3;
      }
      // Initialize controllers
      _indicatorPeriodController.text = _indicatorPeriod.toString();
      _lowerLevelController.text = _lowerLevel.toStringAsFixed(1);
      _upperLevelController.text = _upperLevel.toStringAsFixed(1);
      if (_stochDPeriod != null) {
        _stochDPeriodController.text = _stochDPeriod.toString();
      }
    });
  }

  Future<void> _saveState() async {
    final prefs = await SharedPreferences.getInstance();
    final indicatorType = _appState?.selectedIndicator ?? IndicatorType.rsi;
    await prefs.setString('markets_timeframe', _timeframe);
    await prefs.setInt(
      'markets_${indicatorType.toJson()}_period',
      _indicatorPeriod,
    );
    await prefs.setDouble('markets_${indicatorType.toJson()}_lower_level', _lowerLevel);
    await prefs.setDouble('markets_${indicatorType.toJson()}_upper_level', _upperLevel);
    if (_stochDPeriod != null) {
      await prefs.setInt('markets_stoch_d_period', _stochDPeriod!);
    }
  }

  Future<void> _loadAllIndicatorData() async {
    // Clear cache when refreshing manually
    final currentSymbols = _getCurrentTabSymbols();
    for (final symbol in currentSymbols) {
      _loadedSymbols.remove(symbol.symbol);
      _indicatorDataMap.remove(symbol.symbol);
    }

    // Load visible items first
    await _loadVisibleItems();
  }

  /// Load indicator data for visible items and a few ahead
  Future<void> _loadVisibleItems() async {
    final currentSymbols = _getCurrentTabSymbols();
    if (currentSymbols.isEmpty) return;

    final controller = _scrollControllers[_tabController.index];
    if (controller == null || !controller.hasClients) {
      // Load first batch if scroll controller not ready
      await _loadBatch(currentSymbols, 0, 10);
      return;
    }

    // Calculate visible range (roughly 2 screen heights worth of items)
    final viewportHeight = controller.position.viewportDimension;
    final scrollOffset = controller.offset;
    final itemHeight = 140.0; // Approximate height of each card

    final firstVisibleIndex = (scrollOffset / itemHeight).floor();
    final visibleCount =
        (viewportHeight / itemHeight).ceil() + 2; // +2 for buffer

    // Load visible items + buffer
    final startIndex =
        (firstVisibleIndex - 2).clamp(0, currentSymbols.length - 1);
    final endIndex =
        (firstVisibleIndex + visibleCount + 5).clamp(0, currentSymbols.length);

    await _loadBatch(currentSymbols, startIndex, endIndex);
  }

  /// Load a batch of symbols (lazy loading)
  Future<void> _loadBatch(
      List<SymbolInfo> symbols, int startIndex, int endIndex) async {
    final symbolsToLoad = <String>[];

    for (int i = startIndex; i < endIndex && i < symbols.length; i++) {
      final symbol = symbols[i].symbol;
      // Only load if not already loaded and not currently loading
      if (!_loadedSymbols.contains(symbol) &&
          !_loadingSymbols.contains(symbol)) {
        symbolsToLoad.add(symbol);
      }
    }

    if (symbolsToLoad.isEmpty) return;

    // Load in smaller batches with delay to avoid overwhelming the server
    // Reduced batch size from 5 to 3 to prevent 500 errors
    const batchSize = 3;
    const delayBetweenBatches = Duration(milliseconds: 500);

    for (int i = 0; i < symbolsToLoad.length; i += batchSize) {
      final batch = symbolsToLoad.skip(i).take(batchSize).toList();
      await Future.wait(
        batch.map((symbol) => _loadIndicatorData(symbol)),
        eagerError: false, // Continue even if some fail
      );

      // Add delay between batches to avoid rate limiting
      if (i + batchSize < symbolsToLoad.length) {
        await Future.delayed(delayBetweenBatches);
      }
    }
  }

  List<SymbolInfo> _getCurrentTabSymbols() {
    switch (_tabController.index) {
      case 0:
        return _cryptoSymbols;
      case 1:
        return _indexSymbols;
      case 2:
        return _forexSymbols;
      case 3:
        return _commoditySymbols;
      default:
        return [];
    }
  }

  Future<void> _loadIndicatorData(String symbol) async {
    // Skip if already loaded (unless cache was cleared)
    if (_loadedSymbols.contains(symbol) &&
        _indicatorDataMap.containsKey(symbol)) {
      return;
    }

    // Skip if already loading
    if (_loadingSymbols.contains(symbol)) {
      return;
    }

    _loadingSymbols.add(symbol);

    const maxRetries = 3;
    int attempt = 0;
    final indicatorType = _appState?.selectedIndicator ?? IndicatorType.rsi;

    while (attempt < maxRetries) {
      try {
        // Determine limit depending on timeframe (same as watchlist)
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
          _loadingSymbols.remove(symbol);
          return;
        }

        // Convert candles to format expected by IndicatorService
        final candlesList = candles
            .map(
              (c) => {
                'open': c.open,
                'high': c.high,
                'low': c.low,
                'close': c.close,
                'timestamp': c.timestamp,
              },
            )
            .toList();

        final indicatorParams =
            indicatorType == IndicatorType.stoch && _stochDPeriod != null
                ? {'dPeriod': _stochDPeriod}
                : null;

        final result = IndicatorService.calculateIndicatorHistory(
          candlesList,
          indicatorType,
          _indicatorPeriod,
          indicatorParams,
        );

        if (result.isEmpty) {
          _loadingSymbols.remove(symbol);
          return;
        }

        final currentResult = result.last;
        final previousResult =
            result.length > 1 ? result[result.length - 2] : null;

        // Take only last 50 points for compact chart (same as watchlist)
        final indicatorValues = result.map((r) => r.value).toList();
        final indicatorTimestamps = result.map((r) => r.timestamp).toList();
        final chartIndicatorValues = indicatorValues.length > 50
            ? indicatorValues.sublist(indicatorValues.length - 50)
            : indicatorValues;
        final chartIndicatorTimestamps = indicatorTimestamps.length > 50
            ? indicatorTimestamps.sublist(indicatorTimestamps.length - 50)
            : indicatorTimestamps;
        final chartIndicatorResults = result.length > 50
            ? result.sublist(result.length - 50)
            : result;

        if (mounted) {
          setState(() {
            _indicatorDataMap[symbol] = _SymbolIndicatorData(
              currentValue: currentResult.value,
              previousValue: previousResult?.value,
              history: chartIndicatorValues,
              timestamps: chartIndicatorTimestamps,
              indicatorResults: chartIndicatorResults,
            );
            _loadedSymbols.add(symbol);
          });
        }
        _loadingSymbols.remove(symbol);
        return; // Success, exit retry loop
      } catch (e) {
        attempt++;
        debugPrint(
            'Error loading indicator data for $symbol (attempt $attempt/$maxRetries): $e');

        // Check if it's a 500 error or rate limit error
        final errorStr = e.toString().toLowerCase();
        final isServerError = errorStr.contains('500') ||
            errorStr.contains('error getting data') ||
            errorStr.contains('failed to fetch');

        if (attempt >= maxRetries || !isServerError) {
          // All retries failed or not a retryable error
          debugPrint(
              'Failed to load indicator for $symbol after $maxRetries attempts');
          _loadingSymbols.remove(symbol);
          return;
        } else {
          // Wait before retry with exponential backoff (1s, 2s, 4s)
          final delayMs = 1000 * (1 << (attempt - 1));
          await Future.delayed(Duration(milliseconds: delayMs));
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Markets'),
        backgroundColor: Colors.blue[900],
        foregroundColor: Colors.white,
        bottom: TabBar(
          controller: _tabController,
          onTap: (index) {
            // Load visible items when switching tabs
            unawaited(_loadVisibleItems());
          },
          tabs: const [
            Tab(text: 'Crypto'),
            Tab(text: 'Indexes'),
            Tab(text: 'Forex'),
            Tab(text: 'Commodities'),
          ],
        ),
      ),
      body: Column(
        children: [
          // Indicator selector (always at top)
          if (_appState != null) IndicatorSelector(appState: _appState!),
          
          // Timeframe selector
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Text(
                    loc.t('home_timeframe_label'),
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: _timeframe,
                      decoration: InputDecoration(
                        border: const OutlineInputBorder(),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                      ),
                      isExpanded: true,
                      items: const [
                        DropdownMenuItem(value: '1m', child: Text('1m')),
                        DropdownMenuItem(value: '5m', child: Text('5m')),
                        DropdownMenuItem(value: '15m', child: Text('15m')),
                        DropdownMenuItem(value: '1h', child: Text('1h')),
                        DropdownMenuItem(value: '4h', child: Text('4h')),
                        DropdownMenuItem(value: '1d', child: Text('1d')),
                      ],
                      onChanged: (value) async {
                        if (value != null && value != _timeframe) {
                          setState(() {
                            _timeframe = value;
                          });
                          await _saveState();
                          // Clear cache and reload when timeframe changes
                          _loadedSymbols.clear();
                          _indicatorDataMap.clear();
                          unawaited(_loadVisibleItems());
                        }
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Indicator settings
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                InkWell(
                  onTap: () {
                    setState(() {
                      _settingsExpanded = !_settingsExpanded;
                    });
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Text(
                          _appState != null
                              ? '${_appState!.selectedIndicator.name} Settings'
                              : 'Indicator Settings',
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
                              child: TextField(
                                controller: _indicatorPeriodController,
                                decoration: InputDecoration(
                                  labelText: () {
                                    final indicator = _appState?.selectedIndicator ?? IndicatorType.rsi;
                                    switch (indicator) {
                                      case IndicatorType.stoch:
                                        return '%K Period';
                                      case IndicatorType.williams:
                                        return 'WPR Period';
                                      case IndicatorType.rsi:
                                        return loc.t('home_rsi_period_label');
                                    }
                                  }(),
                                  border: const OutlineInputBorder(),
                                  isDense: true,
                                  contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 8),
                                ),
                                keyboardType: TextInputType.number,
                                onChanged: (value) {
                                  final period = int.tryParse(value);
                                  if (period != null &&
                                      period >= 1 &&
                                      period <= 100 &&
                                      period != _indicatorPeriod) {
                                    setState(() {
                                      _indicatorPeriod = period;
                                    });
                                    _saveState();
                                    // Clear cache and reload when period changes
                                    _loadedSymbols.clear();
                                    _indicatorDataMap.clear();
                                    unawaited(_loadVisibleItems());
                                  }
                                },
                              ),
                            ),
                            if (_appState?.selectedIndicator ==
                                IndicatorType.stoch) ...[
                              const SizedBox(width: 8),
                              Expanded(
                                child: TextField(
                                  controller: _stochDPeriodController,
                                  decoration: const InputDecoration(
                                    labelText: '%D Period',
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                    contentPadding: EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 8),
                                  ),
                                  keyboardType: TextInputType.number,
                                  onChanged: (value) {
                                    final dPeriod = int.tryParse(value);
                                    if (dPeriod != null &&
                                        dPeriod >= 1 &&
                                        dPeriod <= 100) {
                                      setState(() {
                                        _stochDPeriod = dPeriod;
                                      });
                                      _saveState();
                                      // Clear cache and reload when period changes
                                      _loadedSymbols.clear();
                                      _indicatorDataMap.clear();
                                      unawaited(_loadVisibleItems());
                                    }
                                  },
                                ),
                              ),
                            ],
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
                                onChanged: (value) {
                                  final level = double.tryParse(value);
                                  if (level != null &&
                                      level >= 0 &&
                                      level <= 100 &&
                                      level != _lowerLevel) {
                                    setState(() {
                                      _lowerLevel = level;
                                    });
                                    _saveState();
                                    // Reload to update chart levels
                                    setState(() {});
                                  }
                                },
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
                                onChanged: (value) {
                                  final level = double.tryParse(value);
                                  if (level != null &&
                                      level >= 0 &&
                                      level <= 100 &&
                                      level != _upperLevel) {
                                    setState(() {
                                      _upperLevel = level;
                                    });
                                    _saveState();
                                    // Reload to update chart levels
                                    setState(() {});
                                  }
                                },
                              ),
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

          // Tab content
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildSymbolList(_cryptoSymbols, loc),
                _buildSymbolList(_indexSymbols, loc),
                _buildSymbolList(_forexSymbols, loc),
                _buildSymbolList(_commoditySymbols, loc),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSymbolList(List<SymbolInfo> symbols, AppLocalizations loc) {
    if (_isLoading && _indicatorDataMap.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    final tabIndex = _tabController.index;
    final scrollController = _scrollControllers[tabIndex];

    return RefreshIndicator(
      onRefresh: _loadAllIndicatorData,
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          // Load more items when user scrolls near the end
          if (notification is ScrollUpdateNotification) {
            final metrics = notification.metrics;
            // Load more when 80% scrolled
            if (metrics.pixels > metrics.maxScrollExtent * 0.8) {
              unawaited(_loadVisibleItems());
            }
          }
          return false;
        },
        child: ListView.builder(
          controller: scrollController,
          itemCount: symbols.length,
          itemBuilder: (context, index) {
            final symbol = symbols[index];
            final indicatorData = _indicatorDataMap[symbol.symbol];

            // Trigger lazy load when item is about to become visible
            if (indicatorData == null &&
                !_loadingSymbols.contains(symbol.symbol)) {
              // Load this item and nearby items
              WidgetsBinding.instance.addPostFrameCallback((_) {
                unawaited(_loadBatch(
                    symbols,
                    (index - 2).clamp(0, symbols.length),
                    (index + 10).clamp(0, symbols.length)));
              });
            }

            return _buildSymbolCard(symbol, indicatorData, loc);
          },
        ),
      ),
    );
  }

  Widget _buildSymbolCard(
    SymbolInfo symbol,
    _SymbolIndicatorData? indicatorData,
    AppLocalizations loc,
  ) {
    final value = indicatorData?.currentValue;
    final history = indicatorData?.history ?? [];
    final timestamps = indicatorData?.timestamps ?? [];

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: ListTile(
        title: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    symbol.symbol,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  Text(
                    symbol.name,
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  ),
                ],
              ),
            ),
            if (value != null)
              Text(
                value.toStringAsFixed(2),
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                  color: Colors.blue,
                ),
              ),
          ],
        ),
        subtitle: history.isNotEmpty && timestamps.isNotEmpty && indicatorData != null
            ? SizedBox(
                height: 60,
                child: IndicatorChart(
                  indicatorResults: indicatorData.indicatorResults,
                  timestamps: timestamps,
                  indicatorType: _appState!.selectedIndicator,
                  symbol: symbol.symbol,
                  timeframe: _timeframe,
                  levels: [_lowerLevel, _upperLevel],
                  showGrid: false,
                  showLabels: false,
                  isInteractive: false,
                  lineWidth: 1.2,
                ),
              )
            : const SizedBox(height: 40),
        onTap: () {
          // Navigate to home screen with selected symbol
          Navigator.of(context).pushNamedAndRemoveUntil(
            '/home',
            (route) => false,
            arguments: {'symbol': symbol.symbol},
          );
        },
      ),
    );
  }
}

class _SymbolIndicatorData {
  final double currentValue;
  final double? previousValue;
  final List<double> history;
  final List<int> timestamps;
  final List<IndicatorResult> indicatorResults; // Full results for chart

  _SymbolIndicatorData({
    required this.currentValue,
    this.previousValue,
    required this.history,
    required this.timestamps,
    required this.indicatorResults,
  });
}
