import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:isar/isar.dart';
import '../models.dart';
import '../config/app_config.dart';
import '../models/indicator_type.dart';
import '../services/yahoo_proto.dart';
import '../services/widget_service.dart';
import '../services/indicator_service.dart';
import '../widgets/indicator_chart.dart';
import '../widgets/indicator_zone_indicator.dart';
import '../localization/app_localizations.dart';
import '../services/symbol_search_service.dart';
import '../services/alert_sync_service.dart';
import '../services/data_sync_service.dart';
import '../services/auth_service.dart';
import '../services/error_service.dart';
import '../services/notification_service.dart';
import '../state/app_state.dart';
import '../widgets/indicator_selector.dart';
import '../widgets/wpr_level_input_formatter.dart';
import '../utils/context_extensions.dart';
import '../utils/snackbar_helper.dart';
import '../utils/price_formatter.dart';
import '../constants/app_constants.dart';
import '../di/app_container.dart';
import '../repositories/i_alert_repository.dart';
import '../repositories/i_watchlist_repository.dart';
import '../utils/preferences_storage.dart';
import 'alerts_screen.dart';
import 'settings_screen.dart';
import 'create_alert_screen.dart';
import 'watchlist_screen.dart';
import 'markets_screen.dart';

class HomeScreen extends StatefulWidget {
  final Isar isar;
  final String? initialSymbol;
  final String? initialIndicator;

  const HomeScreen({
    super.key,
    required this.isar,
    this.initialSymbol,
    this.initialIndicator,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final YahooProtoSource _yahooService = YahooProtoSource(
    AppConfig.apiBaseUrl,
  );
  static const MethodChannel _channel = MethodChannel(
    'com.indicharts.app/widget',
  );
  late final WidgetService _widgetService;
  late final IWatchlistRepository _watchlistRepository;
  late final IAlertRepository _alertRepository;
  List<AlertRule> _alerts = [];
  String _selectedSymbol = 'AAPL';
  String _selectedTimeframe = '15m';
  int _indicatorPeriod = AppConstants.defaultIndicatorPeriod;
  double _lowerLevel = AppConstants.defaultLevels[0];
  double _upperLevel = AppConstants.defaultLevels[1];
  IndicatorType? _previousIndicatorType; // Track previous indicator to save its settings
  List<double> _indicatorValues = []; // Universal indicator values
  List<IndicatorResult> _indicatorResults = []; // Full indicator results for chart
  List<int> _indicatorTimestamps = []; // Timestamps for each indicator point
  double _currentIndicatorValue = 0.0;
  double? _currentPrice; // Current price (last close)
  bool _isLoading = false;
  bool _indicatorSettingsExpanded = false; // Indicator settings expansion state
  String? _dataSource; // 'cache' or 'yahoo' - shows where data came from
  AppState? _appState; // App state for selected indicator
  int? _stochDPeriod; // Stochastic %D period (only for Stochastic)

  // Controllers for input fields
  final TextEditingController _indicatorPeriodController =
      TextEditingController();
  final TextEditingController _lowerLevelController = TextEditingController();
  final TextEditingController _upperLevelController = TextEditingController();
  final TextEditingController _symbolController = TextEditingController();
  final TextEditingController _stochDPeriodController = TextEditingController();
  // Keep stable focus nodes to prevent keyboard closing / focus jumping on rebuilds.
  final FocusNode _indicatorPeriodFocusNode = FocusNode();
  final FocusNode _stochDPeriodFocusNode = FocusNode();
  final FocusNode _lowerLevelFocusNode = FocusNode();
  final FocusNode _upperLevelFocusNode = FocusNode();
  bool _isSearchingSymbols = false;
  late final SymbolSearchService _symbolSearchService;
  List<SymbolInfo> _popularSymbols = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _watchlistRepository = sl<IWatchlistRepository>();
    _alertRepository = sl<IAlertRepository>();
    _widgetService = WidgetService(yahooService: _yahooService);
    _symbolSearchService = SymbolSearchService(_yahooService);
    _setupMethodChannel();
    _loadSavedState();
    _loadPopularSymbols();
    unawaited(AlertSyncService.syncPendingAlerts());
    // Always refresh data on app open to ensure freshness
    unawaited(_refreshIndicatorData());

    // Ask notification permission once, but only after first frame (prevents UI "freeze" on first install).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(NotificationService.requestOnFirstAppOpenIfNeeded());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Refresh data when app comes to foreground to ensure fresh data
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshIndicatorData());
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _appState = AppStateScope.of(context);
    _previousIndicatorType = _appState?.selectedIndicator;
    _appState?.addListener(_onIndicatorChanged);
    
    // Set indicator from initialIndicator if provided (after appState is available)
    if (widget.initialIndicator != null && _appState != null) {
      _setInitialIndicator();
    }
  }

  Future<void> _setInitialIndicator() async {
    if (widget.initialIndicator == null || _appState == null) return;
    
    try {
      final indicatorType = IndicatorType.fromJson(widget.initialIndicator!);
      if (_appState!.selectedIndicator != indicatorType) {
        await _appState!.setIndicator(indicatorType);
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error setting indicator from initialIndicator: $e');
      }
    }
  }

  void _onIndicatorChanged() async {
    if (_appState != null) {
      final prefs = await PreferencesStorage.instance;
      final indicatorType = _appState!.selectedIndicator;

      // Save current settings for the PREVIOUS indicator before switching
      if (_previousIndicatorType != null && _previousIndicatorType != indicatorType) {
        // Get current values from controllers to ensure we save the latest user input
        final periodFromController = int.tryParse(_indicatorPeriodController.text);
        final lowerFromController = int.tryParse(_lowerLevelController.text)?.toDouble();
        final upperFromController = int.tryParse(_upperLevelController.text)?.toDouble();
        
        // Save view settings - use controller values if valid, otherwise use state variables
        await prefs.setInt(
          'home_${_previousIndicatorType!.toJson()}_period',
          periodFromController ?? _indicatorPeriod,
        );
        await prefs.setDouble(
          'home_${_previousIndicatorType!.toJson()}_lower_level',
          lowerFromController ?? _lowerLevel,
        );
        await prefs.setDouble(
          'home_${_previousIndicatorType!.toJson()}_upper_level',
          upperFromController ?? _upperLevel,
        );
        if (_previousIndicatorType == IndicatorType.stoch) {
          final stochDFromController = int.tryParse(_stochDPeriodController.text);
          await prefs.setInt('home_stoch_d_period', stochDFromController ?? _stochDPeriod ?? 3);
        }
      }

      // Load saved settings for the new indicator, or use defaults
      // IMPORTANT: Always use defaults if no saved settings exist, don't use current values
      final savedPeriod = prefs.getInt('home_${indicatorType.toJson()}_period');
      final savedLowerLevel = prefs.getDouble('home_${indicatorType.toJson()}_lower_level');
      final savedUpperLevel = prefs.getDouble('home_${indicatorType.toJson()}_upper_level');
      
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
          _stochDPeriod = prefs.getInt('home_stoch_d_period') ?? 3;
        } else {
          _stochDPeriod = null;
        }

        // Update controllers
        _indicatorPeriodController.text = _indicatorPeriod.toString();
        _lowerLevelController.text = _lowerLevel.toStringAsFixed(0);
        _upperLevelController.text = _upperLevel.toStringAsFixed(0);
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

      // Reload data when indicator changes
      _loadIndicatorData();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _appState?.removeListener(_onIndicatorChanged);
    // Clean up method channel handler to prevent memory leaks
    _channel.setMethodCallHandler(null);
    _indicatorPeriodController.dispose();
    _lowerLevelController.dispose();
    _upperLevelController.dispose();
    _symbolController.dispose();
    _stochDPeriodController.dispose();
    _indicatorPeriodFocusNode.dispose();
    _stochDPeriodFocusNode.dispose();
    _lowerLevelFocusNode.dispose();
    _upperLevelFocusNode.dispose();
    _symbolSearchService.cancelPending();
    super.dispose();
  }

  void _setupMethodChannel() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'refreshWidget') {
        final timeframe = call.arguments['timeframe'] as String? ?? '15m';
        final rsiPeriod = call.arguments['rsiPeriod'] as int? ?? 14;
        final minimizeAfterUpdate =
            call.arguments['minimizeAfterUpdate'] as bool? ?? false;

        debugPrint(
          'HomeScreen: Refresh widget requested - timeframe: $timeframe, period: $rsiPeriod, minimize: $minimizeAfterUpdate',
        );

        // Update widget with specified timeframe and period
        final indicatorType = _appState?.selectedIndicator ?? IndicatorType.rsi;
        final indicatorParams =
            indicatorType == IndicatorType.stoch && _stochDPeriod != null
                ? {'dPeriod': _stochDPeriod}
                : null;
        await _widgetService.updateWidget(
          timeframe: timeframe,
          rsiPeriod: rsiPeriod,
          indicator: indicatorType,
          indicatorParams: indicatorParams,
        );

        debugPrint('HomeScreen: Widget updated successfully');

        // Small additional delay to ensure data is loaded
        // Native part minimizes application after 2 seconds
      }
    });
  }

  Future<void> _loadSavedState() async {
    final prefs = await PreferencesStorage.instance;

    if (widget.initialSymbol != null) {
      _selectedSymbol = widget.initialSymbol!;
    } else {
      _selectedSymbol = prefs.getString('home_selected_symbol') ?? 'AAPL';
    }

    // Load preferences: from server if authenticated, from cache if anonymous
    if (AuthService.isSignedIn) {
      // Fetch preferences from server
      final prefsData = await DataSyncService.fetchPreferences();
      if (prefsData != null) {
        _selectedSymbol = prefsData['symbol'] as String? ??
            prefs.getString('home_selected_symbol') ??
            'AAPL';
        _selectedTimeframe = prefsData['timeframe'] as String? ??
            prefs.getString('home_selected_timeframe') ??
            '15m';
        final indicatorType = _appState?.selectedIndicator ?? IndicatorType.rsi;
        _indicatorPeriod = prefsData['rsiPeriod'] as int? ??
            prefs.getInt('home_${indicatorType.toJson()}_period') ??
            indicatorType.defaultPeriod;
        
        // Validate levels from server - must be in valid range for current indicator
        final serverLowerLevel = prefsData['lowerLevel'] as double?;
        final serverUpperLevel = prefsData['upperLevel'] as double?;
        final savedLowerLevel = serverLowerLevel ?? prefs.getDouble('home_${indicatorType.toJson()}_lower_level');
        final savedUpperLevel = serverUpperLevel ?? prefs.getDouble('home_${indicatorType.toJson()}_upper_level');
        
        // Check if saved values are in valid range for this indicator
        final savedLowerValid = savedLowerLevel != null &&
            ((indicatorType == IndicatorType.williams && savedLowerLevel >= -100.0 && savedLowerLevel <= 0.0) ||
             (indicatorType != IndicatorType.williams && savedLowerLevel >= 0.0 && savedLowerLevel <= 100.0));
        final savedUpperValid = savedUpperLevel != null &&
            ((indicatorType == IndicatorType.williams && savedUpperLevel >= -100.0 && savedUpperLevel <= 0.0) ||
             (indicatorType != IndicatorType.williams && savedUpperLevel >= 0.0 && savedUpperLevel <= 100.0));
        
        _lowerLevel = savedLowerValid ? savedLowerLevel : indicatorType.defaultLevels.first;
        _upperLevel = savedUpperValid ? savedUpperLevel :
            (indicatorType.defaultLevels.length > 1
                ? indicatorType.defaultLevels[1]
                : 100.0);
        
        // For Stochastic, load saved %D period or use default
        if (indicatorType == IndicatorType.stoch) {
          _stochDPeriod = prefs.getInt('home_stoch_d_period') ?? 3;
        } else {
          _stochDPeriod = null;
        }
      } else {
        // Fallback to local preferences
        _selectedSymbol = prefs.getString('home_selected_symbol') ?? 'AAPL';
        _selectedTimeframe =
            prefs.getString('home_selected_timeframe') ?? '15m';
        final indicatorType = _appState?.selectedIndicator ?? IndicatorType.rsi;
        _indicatorPeriod =
            prefs.getInt('home_${indicatorType.toJson()}_period') ??
                indicatorType.defaultPeriod;
        _lowerLevel =
            prefs.getDouble('home_${indicatorType.toJson()}_lower_level') ??
                indicatorType.defaultLevels.first;
        _upperLevel =
            prefs.getDouble('home_${indicatorType.toJson()}_upper_level') ??
                (indicatorType.defaultLevels.length > 1
                    ? indicatorType.defaultLevels[1]
                    : 100.0);
        
        // For Stochastic, load saved %D period or use default
        if (indicatorType == IndicatorType.stoch) {
          _stochDPeriod = prefs.getInt('home_stoch_d_period') ?? 3;
        } else {
          _stochDPeriod = null;
        }
      }
    } else {
      // Anonymous mode: load from cache
      final cacheData = await DataSyncService.loadPreferencesFromCache();
      _selectedSymbol = cacheData['symbol'] as String? ??
          prefs.getString('home_selected_symbol') ??
          'AAPL';
      _selectedTimeframe = cacheData['timeframe'] as String? ??
          prefs.getString('home_selected_timeframe') ??
          '15m';
      final indicatorType = _appState?.selectedIndicator ?? IndicatorType.rsi;
      _indicatorPeriod = cacheData['rsiPeriod'] as int? ??
          prefs.getInt('home_${indicatorType.toJson()}_period') ??
          indicatorType.defaultPeriod;
      
      // Validate levels from cache - must be in valid range for current indicator
      final cacheLowerLevel = cacheData['lowerLevel'] as double?;
      final cacheUpperLevel = cacheData['upperLevel'] as double?;
      final savedLowerLevel = cacheLowerLevel ?? prefs.getDouble('home_${indicatorType.toJson()}_lower_level');
      final savedUpperLevel = cacheUpperLevel ?? prefs.getDouble('home_${indicatorType.toJson()}_upper_level');
      
      // Check if saved values are in valid range for this indicator
      final savedLowerValid = savedLowerLevel != null &&
          ((indicatorType == IndicatorType.williams && savedLowerLevel >= -100.0 && savedLowerLevel <= 0.0) ||
           (indicatorType != IndicatorType.williams && savedLowerLevel >= 0.0 && savedLowerLevel <= 100.0));
      final savedUpperValid = savedUpperLevel != null &&
          ((indicatorType == IndicatorType.williams && savedUpperLevel >= -100.0 && savedUpperLevel <= 0.0) ||
           (indicatorType != IndicatorType.williams && savedUpperLevel >= 0.0 && savedUpperLevel <= 100.0));
      
      _lowerLevel = savedLowerValid ? savedLowerLevel : indicatorType.defaultLevels.first;
      _upperLevel = savedUpperValid ? savedUpperLevel :
          (indicatorType.defaultLevels.length > 1
              ? indicatorType.defaultLevels[1]
              : 100.0);
      
      // For Stochastic, load saved %D period or use default
      if (indicatorType == IndicatorType.stoch) {
        _stochDPeriod = prefs.getInt('home_stoch_d_period') ?? 3;
      } else {
        _stochDPeriod = null;
      }
    }

    // Initialize symbol controller
    _syncSymbolFieldText(_selectedSymbol);
    // Initialize controllers (without text, use hintText)
    _clearControllers();

    setState(() {});

    // Sync data: fetch from server and push local changes
    if (AuthService.isSignedIn) {
      unawaited(AlertSyncService.fetchAndSyncAlerts());
      unawaited(AlertSyncService.syncPendingAlerts());
      unawaited(DataSyncService.fetchWatchlist());
    }

    _loadAlerts();
    _loadIndicatorData();
  }

  Future<void> _loadPopularSymbols() async {
    try {
      final popular = await _symbolSearchService.getPopularSymbols();
      if (!mounted) return;
      setState(() {
        _popularSymbols = popular;
      });
    } catch (e) {
      debugPrint('Failed to load curated symbols: $e');
    }
  }

  Future<void> _saveState() async {
    final prefs = await PreferencesStorage.instance;
    await prefs.setString('home_selected_symbol', _selectedSymbol);
    await prefs.setString('home_selected_timeframe', _selectedTimeframe);
    final indicatorType = _appState?.selectedIndicator ?? IndicatorType.rsi;
    await prefs.setInt(
      'home_${indicatorType.toJson()}_period',
      _indicatorPeriod,
    );
    await prefs.setDouble(
      'home_${indicatorType.toJson()}_lower_level',
      _lowerLevel,
    );
    await prefs.setDouble(
      'home_${indicatorType.toJson()}_upper_level',
      _upperLevel,
    );
    if (indicatorType == IndicatorType.stoch && _stochDPeriod != null) {
      await prefs.setInt('home_stoch_d_period', _stochDPeriod!);
    }

    // Sync to server if authenticated, or save to cache if anonymous
    unawaited(
      DataSyncService.syncPreferences(
        symbol: _selectedSymbol,
        timeframe: _selectedTimeframe,
        rsiPeriod: _indicatorPeriod,
        lowerLevel: _lowerLevel,
        upperLevel: _upperLevel,
      ),
    );
  }

  Future<void> _loadAlerts() async {
    final alerts = await _alertRepository.getActiveCustomAlerts();
    setState(() {
      _alerts = alerts;
    });
  }

  void _syncSymbolFieldText(String value) {
    _symbolController.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  /// Refresh indicator data by clearing cache and loading fresh data
  /// Used when app opens or comes to foreground to ensure data freshness
  Future<void> _refreshIndicatorData() async {
    if (!mounted) return;

    // Clear cache for current symbol/timeframe to force fresh data fetch
    final cacheKey = '$_selectedSymbol:$_selectedTimeframe';
    DataCache.clearCandles(cacheKey);

    // Load fresh data
    await _loadIndicatorData();
  }

  /// Candle limit for home chart (period + buffer, or base minimum for timeframe).
  int _candleLimitForHome() {
    final periodBuffer = _indicatorPeriod + AppConstants.periodBuffer;
    const baseMinimum = AppConstants.minCandlesForChart;
    return periodBuffer > baseMinimum ? periodBuffer : baseMinimum;
  }

  /// Max chart points to display based on timeframe.
  int _maxChartPointsForTimeframe(String timeframe) {
    switch (timeframe) {
      case '4h':
        return 60;
      case '1d':
        return 90;
      case '1h':
        return 100;
      default:
        return 100;
    }
  }

  Future<void> _loadIndicatorData({String? symbol}) async {
    final requestedSymbol = (symbol ?? _selectedSymbol).trim().toUpperCase();
    if (requestedSymbol.isEmpty) return;

    final previousSymbol = _selectedSymbol;
    setState(() => _isLoading = true);

    final loc = context.loc;

    try {
      final limit = _candleLimitForHome();

      final (candles, dataSource) = await _yahooService.fetchCandlesWithSource(
        requestedSymbol,
        _selectedTimeframe,
        limit: limit,
        debug: kDebugMode,
      );

      debugPrint(
        'HomeScreen: Received ${candles.length} candles for $requestedSymbol $_selectedTimeframe from $dataSource (limit was $limit)',
      );

      if (candles.isEmpty) {
        throw YahooException(
          'No data for $requestedSymbol $_selectedTimeframe',
        );
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

      // Get selected indicator
      final indicatorType = _appState?.selectedIndicator ?? IndicatorType.rsi;

      // Prepare indicator parameters
      Map<String, dynamic>? indicatorParams;
      if (indicatorType == IndicatorType.stoch) {
        indicatorParams = {'dPeriod': _stochDPeriod ?? 3};
      }

      // Calculate indicator using IndicatorService
      final indicatorResults = IndicatorService.calculateIndicatorHistory(
        candlesList,
        indicatorType,
        _indicatorPeriod,
        indicatorParams,
      );

      if (indicatorResults.isEmpty) {
        final minDataRequired = indicatorType == IndicatorType.stoch
            ? _indicatorPeriod + (_stochDPeriod ?? 3) - 1
            : _indicatorPeriod + 1;

        if (candles.length < minDataRequired) {
          if (mounted) {
            context.showError(
              loc.t(
                'home_insufficient_data',
                params: {'count': '${candles.length}'},
              ),
            );
          }
        }
      }

      final maxChartPoints = _maxChartPointsForTimeframe(_selectedTimeframe);

      // Extract values and timestamps from results
      final indicatorValues = indicatorResults.map((r) => r.value).toList();
      final indicatorTimestamps =
          indicatorResults.map((r) => r.timestamp).toList();

      // Take only last points for chart
      final chartIndicatorValues = indicatorValues.length > maxChartPoints
          ? indicatorValues.sublist(indicatorValues.length - maxChartPoints)
          : indicatorValues;
      final chartIndicatorTimestamps =
          indicatorTimestamps.length > maxChartPoints
              ? indicatorTimestamps.sublist(
                  indicatorTimestamps.length - maxChartPoints,
                )
              : indicatorTimestamps;
      final chartIndicatorResults = indicatorResults.length > maxChartPoints
          ? indicatorResults.sublist(
              indicatorResults.length - maxChartPoints,
            )
          : indicatorResults;

      // Get last close price
      final lastPrice = candles.isNotEmpty ? candles.last.close : null;

      setState(() {
        _selectedSymbol = requestedSymbol;
        _indicatorValues = chartIndicatorValues;
        _indicatorTimestamps = chartIndicatorTimestamps;
        _indicatorResults = chartIndicatorResults;
        _currentIndicatorValue =
            indicatorValues.isNotEmpty ? indicatorValues.last : 0.0;
        _currentPrice = lastPrice;
        _dataSource = dataSource;
        _syncSymbolFieldText(requestedSymbol);
      });
      await _saveState();
    } catch (e, stackTrace) {
      if (symbol != null) {
        _syncSymbolFieldText(previousSymbol);
      }
      
      // Log error to server
      ErrorService.logError(
        error: e,
        context: 'home_screen_load_indicator_data',
        symbol: requestedSymbol,
        timeframe: _selectedTimeframe,
        additionalData: {
          'stackTrace': stackTrace.toString(),
        },
      );

      if (mounted) {
        String message;
        if (e is YahooException && e.message.contains('No data')) {
          message = loc.t(
            'home_no_data_for_timeframe',
            params: {'timeframe': _selectedTimeframe},
          );
          if (_selectedTimeframe == '4h' || _selectedTimeframe == '1d') {
            final now = DateTime.now();
            final dayOfWeek = now.weekday;
            if (dayOfWeek == 6 || dayOfWeek == 7) {
              message += '\n${loc.t('home_weekend_hint')}';
            } else {
              message += '\n${loc.t('home_large_timeframe_hint')}';
            }
          } else {
            message += '\n${loc.t('home_check_symbol_hint')}';
          }
        } else {
          // Use ErrorService to get user-friendly message
          message = ErrorService.getUserFriendlyError(e, loc);
        }

        context.showError(message);
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
        title: Row(
          children: [
            Text(loc.t('home_title')),
            // Data source indicator (only visible in debug mode)
            if (kDebugMode && _dataSource != null) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: _dataSource == 'cache'
                      ? Colors.green.withValues(alpha: 0.2)
                      : Colors.orange.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color:
                        _dataSource == 'cache' ? Colors.green : Colors.orange,
                    width: 1,
                  ),
                ),
                child: Text(
                  _dataSource!.toUpperCase(),
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: _dataSource == 'cache'
                        ? Colors.green[300]
                        : Colors.orange[300],
                  ),
                ),
              ),
            ],
          ],
        ),
        titleSpacing: 16, // Default spacing for Overview
        backgroundColor: Colors.blue[900],
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.trending_up),
            tooltip: 'Markets',
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => MarketsScreen(isar: widget.isar),
                ),
              );
            },
          ),
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
              // AlertsScreen will refresh itself when returning
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: loc.t('home_settings_tooltip'),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => SettingsScreen(isar: widget.isar),
              ),
            ),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Indicator selector (always at top, fixed)
                if (_appState != null)
                  IndicatorSelector(appState: _appState!),
                
                // Scrollable content
                Expanded(
                  child: RefreshIndicator(
              onRefresh: _loadIndicatorData,
              child: GestureDetector(
                onTap: () {
                  // Remove focus when tapping on screen
                  FocusScope.of(context).unfocus();
                },
                behavior: HitTestBehavior.opaque,
                child: SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 14,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Symbol and timeframe selection
                      _buildSymbolSelector(),
                      const SizedBox(height: 10),

                            // Indicator settings
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: _buildIndicatorSettingsCard(),
                      ),
                      const SizedBox(height: 10),

                            // Current indicator value
                      _buildCurrentIndicatorCard(),
                      const SizedBox(height: 10),

                      // Indicator chart
                      _buildIndicatorChart(),
                      const SizedBox(height: 10),

                      // Active alerts
                      _buildActiveAlerts(),
                      const SizedBox(height: 10),

                      // Quick actions
                      _buildQuickActions(),
                      const SizedBox(height: 10),

                      // Alpha warning
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8.0),
                        child: Text(
                          loc.t('home_alpha_warning'),
                          style: TextStyle(
                            fontSize: 10,
                            color: Colors.grey[500],
                            fontStyle: FontStyle.italic,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
                  ),
                ),
              ],
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
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Text(
                    loc.t('home_instrument_label'),
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.bookmark_add),
                  tooltip: loc.t('home_add_watchlist'),
                  onPressed: () => _addToWatchlist(_selectedSymbol),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        loc.t('home_symbol_label'),
                        style: const TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                      const SizedBox(height: 4),
                      Autocomplete<SymbolInfo>(
                    optionsBuilder: (TextEditingValue textEditingValue) async {
                      // Check mounted before starting any async work
                      if (!mounted) {
                        return const Iterable<SymbolInfo>.empty();
                      }

                      final query = textEditingValue.text.trim();

                      if (query.isEmpty) {
                        if (_popularSymbols.isEmpty) {
                          try {
                            final popular =
                                await _symbolSearchService.getPopularSymbols();
                            if (!mounted) {
                              return const Iterable<SymbolInfo>.empty();
                            }
                            setState(() {
                              _popularSymbols = popular;
                            });
                            return popular.take(40);
                          } catch (_) {
                            return const Iterable<SymbolInfo>.empty();
                          }
                        }
                        return _popularSymbols.take(40);
                      }

                      if (query.length == 1) {
                        final upper = query.toUpperCase();
                        if (_popularSymbols.isEmpty) {
                          try {
                            final popular =
                                await _symbolSearchService.getPopularSymbols();
                            if (!mounted) {
                              return const Iterable<SymbolInfo>.empty();
                            }
                            setState(() {
                              _popularSymbols = popular;
                            });
                          } catch (_) {
                            return const Iterable<SymbolInfo>.empty();
                          }
                        }
                        if (!mounted) {
                          return const Iterable<SymbolInfo>.empty();
                        }
                        return _popularSymbols
                            .where((symbol) => _matchesSymbol(symbol, upper))
                            .take(25);
                      }

                      if (!_isSearchingSymbols && mounted) {
                        setState(() {
                          _isSearchingSymbols = true;
                        });
                      }

                      try {
                        final suggestions = await _symbolSearchService
                            .resolveSuggestions(query);
                        if (!mounted) {
                          return const Iterable<SymbolInfo>.empty();
                        }
                        setState(() {
                          _isSearchingSymbols = false;
                        });
                        if (suggestions.isEmpty) {
                          return const Iterable<SymbolInfo>.empty();
                        }
                        return suggestions;
                      } catch (e) {
                        debugPrint('Symbol search failed: $e');
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
                      // Sync controller with selected symbol, but only if field is empty or matches
                      // This prevents clearing user input when typing, but shows current symbol when not editing
                      if (textEditingController.text.isEmpty || 
                          textEditingController.text == _symbolController.text) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted && textEditingController.text == _symbolController.text || 
                              (textEditingController.text.isEmpty && _symbolController.text.isNotEmpty)) {
                            if (textEditingController.text != _symbolController.text) {
                              textEditingController.text = _symbolController.text;
                            }
                          }
                        });
                      }

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
                        onFieldSubmitted: (String value) async {
                          if (!mounted) return;
                          // Allow direct symbol input even if it's not in the list
                          final trimmedValue = value.trim().toUpperCase();
                          if (trimmedValue.isNotEmpty) {
                            final normalized = trimmedValue.toUpperCase();
                            _syncSymbolFieldText(normalized);
                            if (normalized != _selectedSymbol && mounted) {
                              await _loadIndicatorData(symbol: normalized);
                            }
                          }
                          // Remove focus on submit
                          if (mounted) {
                            focusNode.unfocus();
                            onFieldSubmitted();
                          }
                        },
                        decoration: InputDecoration(
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
                          // Update _symbolController to keep it in sync
                          // This allows showing current symbol when not editing
                          if (mounted && value != _symbolController.text) {
                            _symbolController.text = value;
                          }
                        },
                      );
                    },
                    onSelected: (SymbolInfo selection) async {
                      if (!mounted) return;
                      final normalized = selection.symbol.toUpperCase();
                      _syncSymbolFieldText(normalized);
                      if (normalized != _selectedSymbol && mounted) {
                        await _loadIndicatorData(symbol: normalized);
                      }
                      // Remove focus after selection
                      if (mounted) {
                        FocusScope.of(context).unfocus();
                      }
                    },
                    optionsViewBuilder: (
                      BuildContext context,
                      AutocompleteOnSelected<SymbolInfo> onSelected,
                      Iterable<SymbolInfo> options,
                    ) {
                      // Use context.loc instead of outer loc to avoid context issues
                      if (options.isEmpty) {
                        return Align(
                          alignment: Alignment.topLeft,
                          child: Material(
                            elevation: 4.0,
                            child: SizedBox(
                              width: double.infinity,
                              height: 56,
                              child: Center(
                                child: Text(
                                  context.loc.t('search_no_results'),
                                  style: const TextStyle(
                                    color: Colors.grey,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      }

                      return Align(
                        alignment: Alignment.topLeft,
                        child: Material(
                          elevation: 4.0,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(
                              maxHeight: 400,
                            ),
                            child: ListView.builder(
                              padding: EdgeInsets.zero,
                              shrinkWrap: true,
                              itemCount: options.length,
                              itemBuilder: (BuildContext context, int index) {
                                final SymbolInfo option = options.elementAt(
                                  index,
                                );
                                return InkWell(
                                  onTap: () {
                                    onSelected(option);
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.all(16.0),
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Wrap(
                                                spacing: 8,
                                                runSpacing: 4,
                                                crossAxisAlignment:
                                                    WrapCrossAlignment.center,
                                                children: [
                                                  Text(
                                                    option.symbol,
                                                    style: const TextStyle(
                                                      fontWeight:
                                                          FontWeight.bold,
                                                    ),
                                                  ),
                                                  if (option.type.isNotEmpty)
                                                    Container(
                                                      padding: const EdgeInsets
                                                          .symmetric(
                                                        horizontal: 8,
                                                        vertical: 4,
                                                      ),
                                                      decoration: BoxDecoration(
                                                        color: Colors
                                                            .blueGrey[900],
                                                        borderRadius:
                                                            BorderRadius
                                                                .circular(
                                                          12,
                                                        ),
                                                      ),
                                                      child: Text(
                                                        option.displayType,
                                                        style: const TextStyle(
                                                          fontSize: 10,
                                                          color: Colors.white,
                                                        ),
                                                      ),
                                                    ),
                                                ],
                                              ),
                                              if (option.name.isNotEmpty &&
                                                  option.name != option.symbol)
                                                Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                    top: 4.0,
                                                  ),
                                                  child: Text(
                                                    option.name,
                                                    style: TextStyle(
                                                      fontSize: 12,
                                                      color: Colors.grey[500],
                                                    ),
                                                  ),
                                                ),
                                              if (option
                                                  .shortExchange.isNotEmpty)
                                                Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                    top: 2.0,
                                                  ),
                                                  child: Text(
                                                    option.shortExchange,
                                                    style: TextStyle(
                                                      fontSize: 11,
                                                      color: Colors.grey[600],
                                                    ),
                                                  ),
                                                ),
                                            ],
                                          ),
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
                  ],
                ),
              ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        loc.t('home_timeframe_label'),
                        style: const TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                      const SizedBox(height: 4),
                      DropdownButtonFormField<String>(
                        initialValue: _selectedTimeframe,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 16,
                          ),
                        ),
                        isExpanded: true,
                        style: TextStyle(
                          fontSize: 14,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
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
                            _loadIndicatorData();
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCurrentIndicatorCard() {
    final loc = context.loc;
    final indicatorType = _appState?.selectedIndicator ?? IndicatorType.rsi;
    final zone = IndicatorService.getIndicatorZone(
        _currentIndicatorValue,
        [
          _lowerLevel,
          _upperLevel,
        ],
        indicatorType);
    final color = IndicatorService.getZoneColor(zone, indicatorType);

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
                    loc.t(
                      'home_current_indicator_title',
                      params: {
                        'indicator': indicatorType.name,
                        'symbol': _selectedSymbol,
                      },
                    ),
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _currentIndicatorValue.toStringAsFixed(1),
                    style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                      color: color,
                    ),
                  ),
                  if (_currentPrice != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      PriceFormatter.formatPrice(_currentPrice!),
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey[500],
                        fontWeight: FontWeight.normal,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            IndicatorZoneIndicator(
              value: _currentIndicatorValue,
              symbol: _selectedSymbol,
              levels: [_lowerLevel, _upperLevel],
              indicatorType: indicatorType,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildIndicatorChart() {
    final loc = context.loc;
    final indicatorType = _appState?.selectedIndicator ?? IndicatorType.rsi;

    if (_indicatorValues.isEmpty) {
      return const SizedBox.shrink();
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.only(
          left: 4,
          right: 4,
          top: 16,
          bottom: 16,
        ), // Minimum horizontal padding for maximum chart stretching
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                loc.t('home_indicator_chart_title', params: {'indicator': indicatorType.name}),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(height: 8),
            IndicatorChart(
              indicatorResults: _indicatorResults,
              timestamps: _indicatorTimestamps,
              indicatorType: indicatorType,
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
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                TextButton(
                  onPressed: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => AlertsScreen(isar: widget.isar),
                      ),
                    );
                    // AlertsScreen will refresh itself when returning via didUpdateWidget
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
              ..._alerts.take(3).map(
                    (alert) => ListTile(
                      title: Text(alert.symbol),
                      subtitle: Text(
                        '${alert.timeframe} • ${alert.levels.join('/')}',
                      ),
                      trailing: Icon(
                        alert.active
                            ? Icons.notifications_active
                            : Icons.notifications_off,
                        color: alert.active ? Colors.green : Colors.grey,
                      ),
                      onTap: () => _editAlert(alert),
                    ),
                  ),
          ],
        ),
      ),
    );
  }

  void _clearControllers() {
    _indicatorPeriodController.clear();
    _lowerLevelController.clear();
    _upperLevelController.clear();
    _stochDPeriodController.clear();
  }

  void _applyIndicatorSettings() {
    final indicatorType = _appState?.selectedIndicator ?? IndicatorType.rsi;
    final period = int.tryParse(_indicatorPeriodController.text);
    final lower = int.tryParse(_lowerLevelController.text)?.toDouble();
    final upper = int.tryParse(_upperLevelController.text)?.toDouble();
    int? stochDPeriod;
    if (indicatorType == IndicatorType.stoch) {
      stochDPeriod = int.tryParse(_stochDPeriodController.text);
    }

    bool changed = false;

    if (period != null &&
        period >= AppConstants.minPeriod &&
        period <= AppConstants.maxPeriod &&
        period != _indicatorPeriod) {
      _indicatorPeriod = period;
      changed = true;
      _saveState();
    }

    if (stochDPeriod != null &&
        stochDPeriod >= 1 &&
        stochDPeriod <= 100 &&
        stochDPeriod != _stochDPeriod) {
      _stochDPeriod = stochDPeriod;
      changed = true;
      _saveState();
    }

    // Validate levels based on indicator type
    // For Williams %R, allow -100 to 0; for others, allow 0 to 100
    final minAllowed = indicatorType == IndicatorType.williams ? -100.0 : 0.0;
    final maxAllowed = indicatorType == IndicatorType.williams ? 0.0 : 100.0;

    if (lower != null &&
        lower >= minAllowed &&
        lower <= maxAllowed &&
        lower < _upperLevel &&
        lower != _lowerLevel) {
      _lowerLevel = lower;
      changed = true;
      _saveState();
    }

    if (upper != null &&
        upper >= minAllowed &&
        upper <= maxAllowed &&
        upper > _lowerLevel &&
        upper != _upperLevel) {
      _upperLevel = upper;
      changed = true;
      _saveState();
    }

    // Update controllers with new values (don't clear them)
    setState(() {
      _indicatorPeriodController.text = _indicatorPeriod.toString();
      _lowerLevelController.text = _lowerLevel.toStringAsFixed(0);
      _upperLevelController.text = _upperLevel.toStringAsFixed(0);
      if (_stochDPeriod != null) {
        _stochDPeriodController.text = _stochDPeriod.toString();
      } else {
        _stochDPeriodController.clear();
      }
    });

    // Recalculate indicator if period changed
    if (changed && period != null) {
      _loadIndicatorData();
    } else if (changed) {
      setState(() {}); // Update only levels
    }
  }

  void _resetIndicatorSettings() {
    final indicatorType = _appState?.selectedIndicator ?? IndicatorType.rsi;
    setState(() {
      _indicatorPeriod = indicatorType.defaultPeriod;
      _lowerLevel = indicatorType.defaultLevels.first;
      _upperLevel = indicatorType.defaultLevels.length > 1
          ? indicatorType.defaultLevels[1]
          : 100.0;
      if (indicatorType == IndicatorType.stoch) {
        _stochDPeriod = 3;
      } else {
        _stochDPeriod = null;
      }
      // Update controllers to show reset values
      _indicatorPeriodController.text = _indicatorPeriod.toString();
      _lowerLevelController.text = _lowerLevel.toStringAsFixed(0);
      _upperLevelController.text = _upperLevel.toStringAsFixed(0);
      if (_stochDPeriod != null) {
        _stochDPeriodController.text = _stochDPeriod.toString();
      } else {
        _stochDPeriodController.clear();
      }
    });
    _saveState();
    _loadIndicatorData();
  }

  Widget _buildIndicatorSettingsCard() {
    final loc = context.loc;
    final indicatorType = _appState?.selectedIndicator ?? IndicatorType.rsi;
    return Card(
      child: Column(
        children: [
          InkWell(
            onTap: () {
              setState(() {
                _indicatorSettingsExpanded = !_indicatorSettingsExpanded;
                // When expanding, fill fields with current values
                if (_indicatorSettingsExpanded) {
                  _indicatorPeriodController.text = _indicatorPeriod.toString();
                  _lowerLevelController.text = _lowerLevel.toStringAsFixed(0);
                  _upperLevelController.text = _upperLevel.toStringAsFixed(0);
                  if (_stochDPeriod != null) {
                    _stochDPeriodController.text = _stochDPeriod.toString();
                  }
                }
              });
            },
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Text(
                    loc.t('markets_indicator_settings'),
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    _indicatorSettingsExpanded
                        ? Icons.expand_less
                        : Icons.expand_more,
                  ),
                ],
              ),
            ),
          ),
          if (_indicatorSettingsExpanded) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  IntrinsicHeight(
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              () {
                                switch (indicatorType) {
                                  case IndicatorType.stoch:
                                    return loc.t('home_stoch_k_period_label');
                                  case IndicatorType.williams:
                                    return loc.t('home_wpr_period_label');
                                  case IndicatorType.rsi:
                                    return loc.t('home_rsi_period_label');
                                }
                              }(),
                              style: const TextStyle(fontSize: 12, color: Colors.grey),
                            ),
                            const Spacer(),
                            TextField(
                              controller: _indicatorPeriodController,
                              focusNode: _indicatorPeriodFocusNode,
                              decoration: const InputDecoration(
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              keyboardType: TextInputType.number,
                              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9]'))],
                            ),
                          ],
                        ),
                      ),
                      if (indicatorType == IndicatorType.stoch) ...[
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                loc.t('home_stoch_d_period_label'),
                                style: const TextStyle(fontSize: 12, color: Colors.grey),
                              ),
                              const Spacer(),
                              TextField(
                                controller: _stochDPeriodController,
                                focusNode: _stochDPeriodFocusNode,
                                decoration: const InputDecoration(
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                                keyboardType: TextInputType.number,
                                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9]'))],
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              loc.t('home_lower_zone_label'),
                              style: const TextStyle(fontSize: 12, color: Colors.grey),
                            ),
                            const Spacer(),
                            TextField(
                              controller: _lowerLevelController,
                              focusNode: _lowerLevelFocusNode,
                              decoration: const InputDecoration(
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              keyboardType: TextInputType.numberWithOptions(signed: (_appState?.selectedIndicator ?? IndicatorType.rsi) == IndicatorType.williams),
                              inputFormatters: (_appState?.selectedIndicator ?? IndicatorType.rsi) == IndicatorType.williams
                                  ? [WprLevelInputFormatter()]
                                  : [FilteringTextInputFormatter.allow(RegExp(r'[0-9]'))],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              loc.t('home_upper_zone_label'),
                              style: const TextStyle(fontSize: 12, color: Colors.grey),
                            ),
                            const Spacer(),
                            TextField(
                              controller: _upperLevelController,
                              focusNode: _upperLevelFocusNode,
                              decoration: const InputDecoration(
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              keyboardType: TextInputType.numberWithOptions(signed: (_appState?.selectedIndicator ?? IndicatorType.rsi) == IndicatorType.williams),
                              inputFormatters: (_appState?.selectedIndicator ?? IndicatorType.rsi) == IndicatorType.williams
                                  ? [WprLevelInputFormatter()]
                                  : [FilteringTextInputFormatter.allow(RegExp(r'[0-9]'))],
                            ),
                          ],
                        ),
                      ),
                    ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.refresh, size: 20),
                        tooltip: loc.t('home_reset_defaults_tooltip'),
                        onPressed: _resetIndicatorSettings,
                        color: Colors.grey[600],
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.check, size: 20),
                        tooltip: loc.t('home_apply_changes_tooltip'),
                        onPressed: _applyIndicatorSettings,
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
                    icon: const Icon(Icons.add_alert, size: 20),
                    label: Text(loc.t('home_create_alert')),
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size(0, 48), // Minimum height for consistency
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => _loadIndicatorData(),
                    icon: const Icon(Icons.refresh, size: 20),
                    label: Text(loc.t('home_refresh')),
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size(0, 48), // Minimum height for consistency
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    ),
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
        builder: (context) => CreateAlertScreen(
          isar: widget.isar,
          initialSymbol: _selectedSymbol.isNotEmpty ? _selectedSymbol : null,
          initialTimeframe: _selectedTimeframe,
          initialPeriod: _indicatorPeriod,
        ),
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

    // Check watchlist limit
    final allExistingItems = await _watchlistRepository.getAll();
    if (allExistingItems.length >= AppConstants.maxWatchlistItems) {
      if (mounted) {
        SnackBarHelper.showInfo(context, loc.t('home_watchlist_limit_reached'));
      }
      return;
    }

    // Check if this symbol is already added
    final existing = await _watchlistRepository.getBySymbol(symbol);

    if (existing != null) {
      if (mounted) {
        context.showInfo(loc.t('home_watchlist_exists', params: {'symbol': symbol}));
      }
      return;
    }

    // Add to watchlist
    // Get all existing items to ensure ID is assigned correctly (already fetched above for limit check)
    debugPrint(
      'HomeScreen: Before adding $symbol there are ${allExistingItems.length} items',
    );
    if (allExistingItems.isNotEmpty) {
      debugPrint(
        'HomeScreen: Existing items: ${allExistingItems.map((e) => '${e.symbol} (id:${e.id})').toList()}',
      );
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

    await _watchlistRepository.put(item);

    // Sync watchlist: to server if authenticated, to cache if anonymous
    if (AuthService.isSignedIn) {
      unawaited(DataSyncService.syncWatchlist());
    } else {
      // In anonymous mode, save to cache
      unawaited(DataSyncService.saveWatchlistToCache());
    }

    debugPrint('HomeScreen: After put() item.id = ${item.id}');

    // Verify that item was actually added
    final allItems = await _watchlistRepository.getAll();
    debugPrint(
      'HomeScreen: After adding $symbol total items: ${allItems.length}',
    );
    debugPrint(
      'HomeScreen: Symbols in watchlist: ${allItems.map((e) => '${e.symbol} (id:${e.id})').toList()}',
    );

    // Verify that new item actually has unique ID
    final addedItem = await _watchlistRepository.findAllBySymbol(symbol);
    debugPrint(
      'HomeScreen: Found items with symbol $symbol: ${addedItem.length}',
    );
    if (addedItem.length > 1) {
      debugPrint(
        'HomeScreen: WARNING! Duplicates for $symbol: ${addedItem.map((e) => e.id).toList()}',
      );
    }

    if (mounted) {
      context.showSuccess(loc.t('home_watchlist_added', params: {'symbol': symbol}));
    }
  }

  bool _matchesSymbol(SymbolInfo info, String upper) {
    final symbolUpper = info.symbol.toUpperCase();
    final nameUpper = info.name.toUpperCase();
    return symbolUpper.startsWith(upper) || nameUpper.startsWith(upper);
  }
}
