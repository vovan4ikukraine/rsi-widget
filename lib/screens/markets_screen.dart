import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:isar/isar.dart';
import '../models/indicator_type.dart';
import '../utils/preferences_storage.dart';
import '../models.dart';
import '../services/yahoo_proto.dart';
import '../services/indicator_service.dart';
import '../services/error_service.dart';
import '../widgets/indicator_chart.dart';
import '../localization/app_localizations.dart';
import '../data/popular_symbols.dart';
import '../state/app_state.dart';
import '../widgets/indicator_selector.dart';
import '../widgets/wpr_level_input_formatter.dart';
import '../utils/price_formatter.dart';
import '../config/app_config.dart';
import '../constants/app_constants.dart';

enum _MarketsSortOrder { none, descending, ascending, marketCap }

class MarketsScreen extends StatefulWidget {
  final Isar isar;

  const MarketsScreen({super.key, required this.isar});

  @override
  State<MarketsScreen> createState() => _MarketsScreenState();
}

class _MarketsScreenState extends State<MarketsScreen>
    with SingleTickerProviderStateMixin {
  final YahooProtoSource _yahooService = YahooProtoSource(
    AppConfig.apiBaseUrl,
  );
  late TabController _tabController;
  AppState? _appState;

  // Settings for all charts
  String _timeframe = '15m';
  int _indicatorPeriod = AppConstants.defaultIndicatorPeriod;
  double _lowerLevel = AppConstants.defaultLevels[0];
  double _upperLevel = AppConstants.defaultLevels[1];
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
  List<SymbolInfo> _stockSymbols = [];

  // Indicator data map: symbol -> indicator data
  final Map<String, _SymbolIndicatorData> _indicatorDataMap = {};
  // Track which symbols are currently being loaded
  final Set<String> _loadingSymbols = {};
  // Track which symbols have been loaded at least once (for cache check)
  final Set<String> _loadedSymbols = {};
  final bool _isLoading = false;
  bool _isActionInProgress = false;

  // Scroll controllers for each tab to detect visible items
  final Map<int, ScrollController> _scrollControllers = {};

  // Sorting
  static const String _sortOrderPrefKey = 'markets_sort_order';
  _MarketsSortOrder _currentSortOrder = _MarketsSortOrder.marketCap;
  // Map to store indicator values for sorting per tab (tabIndex -> symbol -> indicator value)
  final Map<int, Map<String, double>> _indicatorValuesForSorting = {};
  // Track which symbols have indicator values loaded for sorting per tab
  final Map<int, Set<String>> _indicatorValuesLoaded = {};
  bool _isLoadingIndicatorValues = false;
  int _previousTabIndex = 0; // Track previous tab index to detect changes

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
    // Create scroll controllers for each tab
    for (int i = 0; i < 5; i++) {
      _scrollControllers[i] = ScrollController();
    }
    _tabController.addListener(_onTabChanged);
    _loadSymbols();
    // Don't load saved state here - _appState is not available yet
    // Will be loaded in didChangeDependencies() after _appState is set
  }

  void _onTabChanged() {
    // Handle both during change (indexIsChanging) and after change (when index actually changed)
    final currentIndex = _tabController.index;
    if (_tabController.indexIsChanging || currentIndex != _previousTabIndex) {
      // Update previous index
      _previousTabIndex = currentIndex;
      
      // Don't clear values - keep them per tab for faster switching
      // Just trigger rebuild to show new tab's symbols immediately
      if (mounted) {
        setState(() {
          // Trigger rebuild to show symbols immediately
        });
      }
      
      // Load data in background (don't block UI)
      // If sorting by indicator value, load values first
      if (_currentSortOrder == _MarketsSortOrder.descending || 
          _currentSortOrder == _MarketsSortOrder.ascending) {
        unawaited(_loadIndicatorValuesOnly());
      } else {
        unawaited(_loadVisibleItems());
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final previousIndicator = _previousIndicatorType;
    _appState = AppStateScope.of(context);
    final currentIndicator = _appState?.selectedIndicator ?? IndicatorType.rsi;
    
    debugPrint('MarketsScreen: didChangeDependencies called - previousIndicator: $previousIndicator, currentIndicator: $currentIndicator, _indicatorPeriod: $_indicatorPeriod, controller empty: ${_indicatorPeriodController.text.isEmpty}');
    
    // Always check if we need to reload settings when screen becomes visible
    bool needsReload = false;
    
    if (_previousIndicatorType == null || _indicatorPeriodController.text.isEmpty) {
      // First time opening screen or controllers not initialized
      debugPrint('MarketsScreen: First time opening or controllers empty, loading saved state for $currentIndicator');
      needsReload = true;
    } else if (previousIndicator != currentIndicator) {
      // Indicator changed - need to reload with new settings
      debugPrint('MarketsScreen: Indicator changed from $previousIndicator to $currentIndicator, clearing cache');
      needsReload = true;
    }
    
    if (needsReload) {
      _previousIndicatorType = currentIndicator;
      // Clear cache first to ensure old data doesn't show
      _loadedSymbols.clear();
      _indicatorDataMap.clear();
      // Clear indicator values for sorting (all tabs)
      _indicatorValuesForSorting.clear();
      _indicatorValuesLoaded.clear();
      // Load saved state for current indicator, then reload data
      _loadSavedState().then((_) {
        // After loading saved state, load data with correct parameters
        if (mounted) {
          debugPrint('MarketsScreen: Saved state loaded, now loading data with indicator=$currentIndicator, period=$_indicatorPeriod, stochD=$_stochDPeriod');
          // If sorting by indicator value, load values first
          if (_currentSortOrder == _MarketsSortOrder.descending || 
              _currentSortOrder == _MarketsSortOrder.ascending) {
            unawaited(_loadIndicatorValuesOnly());
          } else {
            unawaited(_loadVisibleItems());
          }
        }
      });
    } else {
      // Screen is already initialized - just update previous indicator type
      _previousIndicatorType = currentIndicator;
      // But still check if data needs to be reloaded if cache exists but with wrong parameters
      if (_indicatorDataMap.isNotEmpty && _loadedSymbols.isNotEmpty) {
        debugPrint('MarketsScreen: Screen already initialized with data, checking if reload needed');
      }
    }
    
    _appState?.addListener(_onIndicatorChanged);
  }

  void _onIndicatorChanged() async {
    if (_appState != null && mounted) {
      final prefs = await PreferencesStorage.instance;
      final indicatorType = _appState!.selectedIndicator;
      debugPrint('MarketsScreen: _onIndicatorChanged called for indicator: $indicatorType, previous: $_previousIndicatorType');
      
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
      
      if (mounted) {
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
          _lowerLevelController.text = _lowerLevel.toInt().toString();
          _upperLevelController.text = _upperLevel.toInt().toString();
          if (_stochDPeriod != null) {
            _stochDPeriodController.text = _stochDPeriod.toString();
          } else {
            _stochDPeriodController.clear();
          }
        });
      }

      // Update previous indicator type AFTER loading new settings
      _previousIndicatorType = indicatorType;

      // Save loaded settings so they persist for next time
      await _saveState();

      // Clear cache and reload visible items when indicator changes
      debugPrint('MarketsScreen: Clearing cache and reloading data with indicator=$indicatorType, period=$_indicatorPeriod, stochD=$_stochDPeriod');
      _loadedSymbols.clear();
      _indicatorDataMap.clear();
      // Clear indicator values for sorting when indicator changes (all tabs)
      _indicatorValuesForSorting.clear();
      _indicatorValuesLoaded.clear();
      
      if (mounted) {
        // If sorting by indicator value, load values first
        if (_currentSortOrder == _MarketsSortOrder.descending || 
            _currentSortOrder == _MarketsSortOrder.ascending) {
          unawaited(_loadIndicatorValuesOnly());
        } else {
          unawaited(_loadVisibleItems());
        }
      }
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
    const allSymbols = popularSymbols;

    // Crypto: top 50 by market cap
    _cryptoSymbols =
        allSymbols.where((s) => s.type == 'crypto').take(50).toList();

    // Indexes: all available indices (popular in prop firms)
    _indexSymbols =
        allSymbols.where((s) => s.type == 'index').toList();

    // Forex: all available forex pairs (popular in prop firms)
    _forexSymbols =
        allSymbols.where((s) => s.type == 'currency').toList();

    // Stocks: popular stocks traded in prop firms (NVDA, TSLA, etc.)
    _stockSymbols = allSymbols
        .where((s) => s.type == 'equity')
        .take(50) // Top 50 stocks
        .toList();

    // Commodities: popular in prop firms (FTMO, 5ers, Funding Pips)
    _commoditySymbols = const [
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
        symbol: 'CC=F',
        name: 'Cocoa Futures',
        type: 'commodity',
        currency: 'USD',
        exchange: 'ICE',
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
      SymbolInfo(
        symbol: 'ZM=F',
        name: 'Soybean Meal Futures',
        type: 'commodity',
        currency: 'USD',
        exchange: 'CBOT',
      ),
      SymbolInfo(
        symbol: 'LE=F',
        name: 'Live Cattle Futures',
        type: 'commodity',
        currency: 'USD',
        exchange: 'CME',
      ),
      SymbolInfo(
        symbol: 'HE=F',
        name: 'Lean Hogs Futures',
        type: 'commodity',
        currency: 'USD',
        exchange: 'CME',
      ),
    ];

    // Don't load indicator data here - wait until _loadSavedState() sets correct parameters
    // Data will be loaded in didChangeDependencies() after settings are loaded
  }

  Future<void> _loadSavedState() async {
    final prefs = await PreferencesStorage.instance;
    final indicatorType = _appState?.selectedIndicator ?? IndicatorType.rsi;
    
    // Load levels with validation to ensure they match the current indicator type
    final savedLowerLevel = prefs.getDouble('markets_${indicatorType.toJson()}_lower_level');
    final savedUpperLevel = prefs.getDouble('markets_${indicatorType.toJson()}_upper_level');
    
    // Validate saved levels match the current indicator type
    final savedLowerValid = savedLowerLevel != null &&
        ((indicatorType == IndicatorType.williams && savedLowerLevel >= -100.0 && savedLowerLevel <= 0.0) ||
         (indicatorType != IndicatorType.williams && savedLowerLevel >= 0.0 && savedLowerLevel <= 100.0));
    final savedUpperValid = savedUpperLevel != null &&
        ((indicatorType == IndicatorType.williams && savedUpperLevel >= -100.0 && savedUpperLevel <= 0.0) ||
         (indicatorType != IndicatorType.williams && savedUpperLevel >= 0.0 && savedUpperLevel <= 100.0));
    
    // Load saved sort order
    final savedSortOrder = prefs.getString(_sortOrderPrefKey);
    
    if (mounted) {
      setState(() {
        _timeframe = prefs.getString('markets_timeframe') ?? '15m';
        _indicatorPeriod =
            prefs.getInt('markets_${indicatorType.toJson()}_period') ??
                indicatorType.defaultPeriod;
        _lowerLevel = savedLowerValid ? savedLowerLevel : indicatorType.defaultLevels.first;
        _upperLevel = savedUpperValid ? savedUpperLevel :
            (indicatorType.defaultLevels.length > 1
                ? indicatorType.defaultLevels[1]
                : 100.0);
        if (indicatorType == IndicatorType.stoch) {
          _stochDPeriod = prefs.getInt('markets_stoch_d_period') ?? 3;
        } else {
          _stochDPeriod = null;
        }
        // Initialize controllers
        _indicatorPeriodController.text = _indicatorPeriod.toString();
        _lowerLevelController.text = _lowerLevel.toInt().toString();
        _upperLevelController.text = _upperLevel.toInt().toString();
        if (_stochDPeriod != null) {
          _stochDPeriodController.text = _stochDPeriod.toString();
        } else {
          _stochDPeriodController.clear();
        }
        
        // Load sort order
        if (savedSortOrder != null) {
        _currentSortOrder = _sortOrderFromString(savedSortOrder);
      } else {
        _currentSortOrder = _MarketsSortOrder.marketCap;
      }
      });
    }
  }

  String _sortOrderToString(_MarketsSortOrder order) {
    switch (order) {
      case _MarketsSortOrder.ascending:
        return 'ascending';
      case _MarketsSortOrder.descending:
        return 'descending';
      case _MarketsSortOrder.marketCap:
        return 'marketCap';
      case _MarketsSortOrder.none:
        return 'none';
    }
  }

  _MarketsSortOrder _sortOrderFromString(String? value) {
    switch (value) {
      case 'ascending':
        return _MarketsSortOrder.ascending;
      case 'descending':
        return _MarketsSortOrder.descending;
      case 'marketCap':
        return _MarketsSortOrder.marketCap;
      default:
        return _MarketsSortOrder.marketCap;
    }
  }

  Future<void> _saveSortOrderPreference(_MarketsSortOrder order) async {
    final prefs = await PreferencesStorage.instance;
    await prefs.setString(_sortOrderPrefKey, _sortOrderToString(order));
  }

  Future<void> _applySortOrder(_MarketsSortOrder order) async {
    if (_isLoading || _isActionInProgress) return;

    setState(() {
      _currentSortOrder = order;
    });

    await _saveSortOrderPreference(order);

    // If sorting by indicator value, load values first
    if (order == _MarketsSortOrder.descending || order == _MarketsSortOrder.ascending) {
      // Clear existing values for current tab if indicator changed
      final tabIndex = _tabController.index;
      _indicatorValuesForSorting[tabIndex]?.clear();
      _indicatorValuesLoaded[tabIndex]?.clear();
      
      // Trigger immediate rebuild to show symbols
      if (mounted) {
        setState(() {
          // Show symbols immediately
        });
      }
      
      // Load indicator values for all symbols in background
      unawaited(_loadIndicatorValuesOnly());
    } else if (order == _MarketsSortOrder.marketCap) {
      // For market cap sorting, just reload visible items (no need to load indicator values)
      _loadedSymbols.clear();
      _indicatorDataMap.clear();
      unawaited(_loadVisibleItems());
    } else {
      // For none sorting, just reload visible items
      _loadedSymbols.clear();
      _indicatorDataMap.clear();
      unawaited(_loadVisibleItems());
    }
  }

  Future<void> _saveState() async {
    final prefs = await PreferencesStorage.instance;
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
      final indicatorType = _appState?.selectedIndicator ?? IndicatorType.rsi;
      final period = int.tryParse(_indicatorPeriodController.text);
      
      // Parse levels - handle negative values for Williams %R
      double? lower;
      double? upper;
      final lowerText = _lowerLevelController.text.trim();
      final upperText = _upperLevelController.text.trim();
      
      if (lowerText.isNotEmpty) {
        // Try parsing as double first (handles negative values)
        lower = double.tryParse(lowerText);
        // If that fails, try as int
        lower ??= int.tryParse(lowerText)?.toDouble();
      }
      
      if (upperText.isNotEmpty) {
        // Try parsing as double first (handles negative values)
        upper = double.tryParse(upperText);
        // If that fails, try as int
        upper ??= int.tryParse(upperText)?.toDouble();
      }
      
      final stochDPeriod = indicatorType == IndicatorType.stoch 
          ? int.tryParse(_stochDPeriodController.text)
          : null;

      bool changed = false;

      if (period != null &&
          period >= AppConstants.minPeriod &&
          period <= AppConstants.maxPeriod &&
          period != _indicatorPeriod) {
        _indicatorPeriod = period;
        changed = true;
      }

      // For Stochastic, check if %D period changed
      if (indicatorType == IndicatorType.stoch && stochDPeriod != null &&
          stochDPeriod >= 1 && stochDPeriod <= 100 &&
          stochDPeriod != _stochDPeriod) {
        _stochDPeriod = stochDPeriod;
        changed = true;
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
      }

      if (upper != null &&
          upper >= minAllowed &&
          upper <= maxAllowed &&
          upper > _lowerLevel &&
          upper != _upperLevel) {
        _upperLevel = upper;
        changed = true;
      }

      // Save state only if something changed
      if (changed) {
        await _saveState();
        
        // Clear cache and reload when settings change
        _loadedSymbols.clear();
        _indicatorDataMap.clear();
        // Clear indicator values for sorting when settings change (all tabs)
        _indicatorValuesForSorting.clear();
        _indicatorValuesLoaded.clear();
        
        // If sorting by indicator value, load values first
        if (_currentSortOrder == _MarketsSortOrder.descending || 
            _currentSortOrder == _MarketsSortOrder.ascending) {
          await _loadIndicatorValuesOnly();
        } else {
          await _loadVisibleItems();
        }
      }

      // Update controllers with current values after applying settings
      if (mounted) {
        setState(() {
          _indicatorPeriodController.text = _indicatorPeriod.toString();
          _lowerLevelController.text = _lowerLevel.toStringAsFixed(0);
          _upperLevelController.text = _upperLevel.toStringAsFixed(0);
          if (indicatorType == IndicatorType.stoch) {
            if (_stochDPeriod != null) {
              _stochDPeriodController.text = _stochDPeriod.toString();
            } else {
              _stochDPeriodController.clear();
            }
          } else {
            _stochDPeriodController.clear();
          }
        });
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
      final indicatorType = _appState?.selectedIndicator ?? IndicatorType.rsi;
      if (mounted) {
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
      }
      await _saveState();
      
      // Clear cache and reload with reset values
      _loadedSymbols.clear();
      _indicatorDataMap.clear();
      await _loadVisibleItems();
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
    // If sorting by indicator value, ensure values are loaded first
    if (_currentSortOrder == _MarketsSortOrder.descending || 
        _currentSortOrder == _MarketsSortOrder.ascending) {
      final tabIndex = _tabController.index;
      final loadedForTab = _indicatorValuesLoaded[tabIndex] ?? {};
      final currentSymbols = _getCurrentTabSymbols();
      if (!_isLoadingIndicatorValues && 
          loadedForTab.length < currentSymbols.length) {
        // Still loading indicator values, start loading but don't wait
        unawaited(_loadIndicatorValuesOnly());
        // Continue loading visible items anyway (they'll be sorted as values arrive)
      }
    }
    
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
    const itemHeight = 140.0; // Approximate height of each card

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

    // Get current parameters once per batch to avoid repeated SharedPreferences reads
    // This ensures we use correct values while optimizing performance
    final prefs = await PreferencesStorage.instance;
    final indicatorType = _appState?.selectedIndicator ?? IndicatorType.rsi;
    final indicatorKey = indicatorType.toJson();
    final currentPeriod = prefs.getInt('markets_${indicatorKey}_period') ?? indicatorType.defaultPeriod;
    final currentStochD = indicatorType == IndicatorType.stoch 
        ? (prefs.getInt('markets_stoch_d_period') ?? 3)
        : null;

    // Load in batches; load test showed 100 concurrent without 429
    const batchSize = 8;
    const delayBetweenBatches = Duration(milliseconds: 150);

    for (int i = 0; i < symbolsToLoad.length; i += batchSize) {
      final batch = symbolsToLoad.skip(i).take(batchSize).toList();
      await Future.wait(
        batch.map((symbol) => _loadIndicatorData(symbol, currentPeriod, currentStochD)),
        eagerError: false, // Continue even if some fail
      );

      // Add delay between batches to avoid rate limiting
      if (i + batchSize < symbolsToLoad.length) {
        await Future.delayed(delayBetweenBatches);
      }
    }
  }

  List<SymbolInfo> _getCurrentTabSymbols() {
    List<SymbolInfo> symbols;
    switch (_tabController.index) {
      case 0:
        symbols = List.from(_cryptoSymbols);
        break;
      case 1:
        symbols = List.from(_indexSymbols);
        break;
      case 2:
        symbols = List.from(_forexSymbols);
        break;
      case 3:
        symbols = List.from(_commoditySymbols);
        break;
      case 4:
        symbols = List.from(_stockSymbols);
        break;
      default:
        return [];
    }

    // Always apply sorting (no none state)
    return _applySortingToSymbols(symbols);
  }

  List<SymbolInfo> _applySortingToSymbols(List<SymbolInfo> symbols) {
    final sorted = List<SymbolInfo>.from(symbols);
    final tabIndex = _tabController.index;
    final valuesForTab = _indicatorValuesForSorting[tabIndex] ?? {};
    
    switch (_currentSortOrder) {
      case _MarketsSortOrder.descending:
        sorted.sort((a, b) {
          final valueA = valuesForTab[a.symbol] ?? double.negativeInfinity;
          final valueB = valuesForTab[b.symbol] ?? double.negativeInfinity;
          final comparison = valueB.compareTo(valueA);
          if (comparison != 0) return comparison;
          // If values are equal, maintain original order
          final indexA = symbols.indexWhere((s) => s.symbol == a.symbol);
          final indexB = symbols.indexWhere((s) => s.symbol == b.symbol);
          return indexA.compareTo(indexB);
        });
        break;
      case _MarketsSortOrder.ascending:
        sorted.sort((a, b) {
          final valueA = valuesForTab[a.symbol] ?? double.infinity;
          final valueB = valuesForTab[b.symbol] ?? double.infinity;
          final comparison = valueA.compareTo(valueB);
          if (comparison != 0) return comparison;
          // If values are equal, maintain original order
          final indexA = symbols.indexWhere((s) => s.symbol == a.symbol);
          final indexB = symbols.indexWhere((s) => s.symbol == b.symbol);
          return indexA.compareTo(indexB);
        });
        break;
      case _MarketsSortOrder.marketCap:
        // Sort by market cap (order in original list - crypto symbols are already sorted by market cap)
        // For crypto tab, use original order (already sorted by market cap)
        // For other tabs, maintain original order
        if (tabIndex == 0) {
          // Crypto tab - symbols are already sorted by market cap in the list
          // Just maintain the original order
          sorted.sort((a, b) {
            final indexA = _cryptoSymbols.indexWhere((s) => s.symbol == a.symbol);
            final indexB = _cryptoSymbols.indexWhere((s) => s.symbol == b.symbol);
            // If not found in original list, put at end
            if (indexA == -1 && indexB == -1) return 0;
            if (indexA == -1) return 1;
            if (indexB == -1) return -1;
            return indexA.compareTo(indexB);
          });
        }
        // For other tabs, market cap sorting doesn't apply, maintain original order
        break;
      case _MarketsSortOrder.none:
        // Fallback - treat as marketCap
        // For crypto tab, maintain original order
        if (tabIndex == 0) {
          sorted.sort((a, b) {
            final indexA = _cryptoSymbols.indexWhere((s) => s.symbol == a.symbol);
            final indexB = _cryptoSymbols.indexWhere((s) => s.symbol == b.symbol);
            if (indexA == -1 && indexB == -1) return 0;
            if (indexA == -1) return 1;
            if (indexB == -1) return -1;
            return indexA.compareTo(indexB);
          });
        }
        break;
    }
    
    return sorted;
  }

  /// Load only indicator values for all symbols (for sorting purposes)
  /// This is lighter than full data load as it doesn't need full candle history
  Future<void> _loadIndicatorValuesOnly() async {
    if (_isLoadingIndicatorValues) return;
    
    // Check if we need to load values for sorting
    if (_currentSortOrder != _MarketsSortOrder.descending &&
        _currentSortOrder != _MarketsSortOrder.ascending) {
      // Not sorting by indicator value, no need to load
      return;
    }

    final tabIndex = _tabController.index;
    
    // Get original symbols list (not sorted) for current tab
    List<SymbolInfo> originalSymbols;
    switch (tabIndex) {
      case 0:
        originalSymbols = _cryptoSymbols;
        break;
      case 1:
        originalSymbols = _indexSymbols;
        break;
      case 2:
        originalSymbols = _forexSymbols;
        break;
      case 3:
        originalSymbols = _commoditySymbols;
        break;
      case 4:
        originalSymbols = _stockSymbols;
        break;
      default:
        return;
    }
    
    if (originalSymbols.isEmpty) return;

    // Initialize maps for this tab if needed
    _indicatorValuesForSorting[tabIndex] ??= {};
    _indicatorValuesLoaded[tabIndex] ??= {};

    // Filter symbols that don't have values loaded yet for this tab
    final loadedForTab = _indicatorValuesLoaded[tabIndex] ?? <String>{};
    final symbolsToLoad = originalSymbols
        .where((s) => !loadedForTab.contains(s.symbol))
        .map((s) => s.symbol)
        .toList();

    if (symbolsToLoad.isEmpty) return;

    _isLoadingIndicatorValues = true;

    final prefs = await PreferencesStorage.instance;
    final indicatorType = _appState?.selectedIndicator ?? IndicatorType.rsi;
    final indicatorKey = indicatorType.toJson();
    final currentPeriod = prefs.getInt('markets_${indicatorKey}_period') ?? indicatorType.defaultPeriod;
    final currentStochD = indicatorType == IndicatorType.stoch 
        ? (prefs.getInt('markets_stoch_d_period') ?? 3)
        : null;

    // Load in batches; load test showed 100 concurrent without 429
    const batchSize = 10;
    const delayBetweenBatches = Duration(milliseconds: 100);

    for (int i = 0; i < symbolsToLoad.length; i += batchSize) {
      final batch = symbolsToLoad.skip(i).take(batchSize).toList();
      await Future.wait(
        batch.map((symbol) => _loadSingleIndicatorValue(
          symbol,
          indicatorType,
          currentPeriod,
          currentStochD,
        )),
        eagerError: false, // Continue even if some fail
      );

      // Add delay between batches
      if (i + batchSize < symbolsToLoad.length) {
        await Future.delayed(delayBetweenBatches);
      }
    }

    _isLoadingIndicatorValues = false;

    // After loading values, apply sorting and reload visible items
    if (mounted) {
      setState(() {
        // Trigger rebuild with sorted list
      });
      // Load visible items in background, don't wait
      unawaited(_loadVisibleItems());
    }
  }

  /// Load only the latest indicator value for a single symbol (lightweight)
  Future<void> _loadSingleIndicatorValue(
    String symbol,
    IndicatorType indicatorType,
    int period,
    int? stochD,
  ) async {
    final tabIndex = _tabController.index;
    final loadedForTab = _indicatorValuesLoaded[tabIndex] ?? <String>{};
    if (loadedForTab.contains(symbol)) return;

    try {
      // Calculate minimum candles needed (period + buffer)
      final periodBuffer = period + AppConstants.periodBuffer;
      final limit = periodBuffer > AppConstants.minCandlesForChart
          ? periodBuffer
          : AppConstants.minCandlesForChart;

      final candles = await _yahooService.fetchCandles(
        symbol,
        _timeframe,
        limit: limit,
      );

      if (candles.isEmpty) {
        final tabIndex = _tabController.index;
        _indicatorValuesLoaded[tabIndex] ??= <String>{};
        _indicatorValuesLoaded[tabIndex]!.add(symbol);
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
          indicatorType == IndicatorType.stoch && stochD != null
              ? {'dPeriod': stochD}
              : null;

      final result = IndicatorService.calculateIndicatorHistory(
        candlesList,
        indicatorType,
        period,
        indicatorParams,
      );

      if (result.isNotEmpty) {
        final currentValue = result.last.value;
        final tabIndex = _tabController.index;
        _indicatorValuesForSorting[tabIndex] ??= {};
        _indicatorValuesForSorting[tabIndex]![symbol] = currentValue;
      }

      final tabIndex = _tabController.index;
      _indicatorValuesLoaded[tabIndex] ??= {};
      _indicatorValuesLoaded[tabIndex]!.add(symbol);
    } catch (e) {
      debugPrint('MarketsScreen: Error loading indicator value for $symbol: $e');
      final tabIndex = _tabController.index;
      _indicatorValuesLoaded[tabIndex] ??= {};
      _indicatorValuesLoaded[tabIndex]!.add(symbol); // Mark as loaded to avoid retrying
    }
  }

  Future<void> _loadIndicatorData(String symbol, [int? periodParam, int? stochDParam]) async {
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
    
    // Use provided parameters if available, otherwise read from SharedPreferences
    // This optimizes by reading once per batch instead of once per symbol
    final currentPeriod = periodParam ?? _indicatorPeriod;
    final currentStochD = stochDParam ?? _stochDPeriod;
    
    debugPrint('MarketsScreen: _loadIndicatorData for $symbol with indicator=$indicatorType, period=$currentPeriod (state period: $_indicatorPeriod), stochD=$currentStochD (state stochD: $_stochDPeriod)');

    while (attempt < maxRetries) {
      try {
        // Calculate optimal candle limit based on timeframe and period (same logic as CRON)
        // Minimum candles required: period + buffer
        final periodBuffer = currentPeriod + AppConstants.periodBuffer;
        
        // Base minimums per timeframe
        int baseMinimum;
        switch (_timeframe) {
          case '4h':
            baseMinimum = AppConstants.minCandlesForChart;
            break;
          case '1d':
            baseMinimum = AppConstants.minCandlesForChart;
            break;
          default:
            // 1m, 5m, 15m, 1h: base minimum for charts and stability
            baseMinimum = AppConstants.minCandlesForChart;
            break;
        }
        
        // Return max of period requirement and base minimum
        final limit = periodBuffer > baseMinimum ? periodBuffer : baseMinimum;

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
            indicatorType == IndicatorType.stoch && currentStochD != null
                ? {'dPeriod': currentStochD}
                : null;

        final result = IndicatorService.calculateIndicatorHistory(
          candlesList,
          indicatorType,
          currentPeriod,
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

        // Get last close price
        final lastPrice = candles.isNotEmpty ? candles.last.close : null;

        if (mounted) {
          setState(() {
            _indicatorDataMap[symbol] = _SymbolIndicatorData(
              currentValue: currentResult.value,
              previousValue: previousResult?.value,
              history: chartIndicatorValues,
              timestamps: chartIndicatorTimestamps,
              indicatorResults: chartIndicatorResults,
              price: lastPrice,
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

        // Log error to server (only on final attempt to avoid spam)
        if (attempt >= maxRetries) {
          ErrorService.logError(
            error: e,
            context: 'markets_screen_load_indicator',
            symbol: symbol,
            timeframe: _timeframe,
            additionalData: {'attempt': attempt.toString()},
          );
        }

        // Check if it's a 500 error or rate limit error
        final errorStr = e.toString().toLowerCase();
        final isServerError = errorStr.contains('500') ||
            errorStr.contains('error getting data') ||
            errorStr.contains('failed to fetch');

        if (attempt >= maxRetries || !isServerError) {
          // All retries failed or not a retryable error
          debugPrint(
              'Failed to load indicator for $symbol after $maxRetries attempts');
          
          // Set empty data to show "no data" message
          if (mounted) {
            setState(() {
              _indicatorDataMap[symbol] = _SymbolIndicatorData(
                currentValue: 0.0,
                previousValue: null,
                history: [],
                timestamps: [],
                indicatorResults: [],
                price: null,
              );
              _loadedSymbols.add(symbol);
            });
          }
          
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
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    
    // Tab texts for width calculation
    final tabTexts = [
      loc.t('markets_crypto'),
      loc.t('markets_indexes'),
      loc.t('markets_forex'),
      loc.t('markets_commodities'),
      loc.t('markets_stocks'),
    ];
    
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(loc.t('markets_title')),
            if (_isLoading || _isActionInProgress || _isLoadingIndicatorValues) ...[
              const SizedBox(width: 12),
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              ),
            ],
          ],
        ),
        titleSpacing: 8, // Reduce spacing between back button and title
        backgroundColor: Colors.blue[900],
        foregroundColor: Colors.white,
        actions: [
          // Timeframe selector button
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 8.0),
            child: PopupMenuButton<String>(
              tooltip: loc.t('home_timeframe_label'),
              onSelected: (value) async {
                if (value != _timeframe) {
                  if (mounted) {
                    setState(() {
                      _timeframe = value;
                    });
                  }
                  await _saveState();
                  // Clear cache and reload when timeframe changes
                  _loadedSymbols.clear();
                  _indicatorDataMap.clear();
                  unawaited(_loadVisibleItems());
                }
              },
              itemBuilder: (BuildContext context) => [
                const PopupMenuItem(value: '1m', child: Text('1m')),
                const PopupMenuItem(value: '5m', child: Text('5m')),
                const PopupMenuItem(value: '15m', child: Text('15m')),
                const PopupMenuItem(value: '1h', child: Text('1h')),
                const PopupMenuItem(value: '4h', child: Text('4h')),
                const PopupMenuItem(value: '1d', child: Text('1d')),
              ],
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.3),
                    width: 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _timeframe,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Icon(
                      Icons.arrow_drop_down,
                      size: 18,
                      color: Colors.white,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Estimate total width needed for all tabs
              const textStyle = TextStyle(fontSize: 14);
              final textPainter = TextPainter(
                textDirection: TextDirection.ltr,
                text: const TextSpan(text: '', style: textStyle),
              );
              
              double maxTabTextWidth = 0;
              for (final text in tabTexts) {
                textPainter.text = TextSpan(text: text, style: textStyle);
                textPainter.layout();
                final textWidth = textPainter.width;
                if (textWidth > maxTabTextWidth) {
                  maxTabTextWidth = textWidth;
                }
              }
              
              // Check if all tabs fit on screen when stretched to fill width
              // Each tab will get availableWidth / tabCount when stretched
              // We need to ensure the widest tab's text fits in that space
              final availableWidth = constraints.maxWidth;
              final widthPerTab = availableWidth / tabTexts.length;
              // Check if the widest tab's text fits in allocated space
              // Add some margin (20px) for padding and safety
              final fitsOnScreen = maxTabTextWidth <= widthPerTab - 20;
              
              return TabBar(
                controller: _tabController,
                isScrollable: !fitsOnScreen,
                tabAlignment: fitsOnScreen ? TabAlignment.fill : TabAlignment.start,
                labelColor: Colors.white,
                unselectedLabelColor: isDark ? Colors.grey[400] : Colors.white.withValues(alpha: 0.9),
                labelStyle: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
                unselectedLabelStyle: const TextStyle(
                  fontWeight: FontWeight.w500, // Slightly bolder for better visibility
                  fontSize: 14,
                ),
                indicatorColor: Colors.white,
                indicatorWeight: 3,
                labelPadding: EdgeInsets.zero,
                padding: EdgeInsets.zero,
                dividerColor: Colors.transparent,
                tabs: [
                  Tab(
                    child: fitsOnScreen
                        ? Center(
                            child: Text(
                              loc.t('markets_crypto'),
                              overflow: TextOverflow.ellipsis,
                              softWrap: false,
                            ),
                          )
                        : Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            child: Text(
                              loc.t('markets_crypto'),
                              overflow: TextOverflow.ellipsis,
                              softWrap: false,
                            ),
                          ),
                  ),
                  Tab(
                    child: fitsOnScreen
                        ? Center(
                            child: Text(
                              loc.t('markets_indexes'),
                              overflow: TextOverflow.ellipsis,
                              softWrap: false,
                            ),
                          )
                        : Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            child: Text(
                              loc.t('markets_indexes'),
                              overflow: TextOverflow.ellipsis,
                              softWrap: false,
                            ),
                          ),
                  ),
                  Tab(
                    child: fitsOnScreen
                        ? Center(
                            child: Text(
                              loc.t('markets_forex'),
                              overflow: TextOverflow.ellipsis,
                              softWrap: false,
                            ),
                          )
                        : Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            child: Text(
                              loc.t('markets_forex'),
                              overflow: TextOverflow.ellipsis,
                              softWrap: false,
                            ),
                          ),
                  ),
                  Tab(
                    child: fitsOnScreen
                        ? Center(
                            child: Text(
                              loc.t('markets_commodities'),
                              overflow: TextOverflow.ellipsis,
                              softWrap: false,
                            ),
                          )
                        : Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            child: Text(
                              loc.t('markets_commodities'),
                              overflow: TextOverflow.ellipsis,
                              softWrap: false,
                            ),
                          ),
                  ),
                  Tab(
                    child: fitsOnScreen
                        ? Center(
                            child: Text(
                              loc.t('markets_stocks'),
                              overflow: TextOverflow.ellipsis,
                              softWrap: false,
                            ),
                          )
                        : Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            child: Text(
                              loc.t('markets_stocks'),
                              overflow: TextOverflow.ellipsis,
                              softWrap: false,
                            ),
                          ),
                  ),
                ],
                onTap: (index) {
                  // Trigger immediate rebuild to show symbols
                  if (mounted) {
                    setState(() {
                      // Show symbols immediately
                    });
                  }
                  // Load data in background (don't block UI)
                  // If sorting by indicator value, load values first
                  if (_currentSortOrder == _MarketsSortOrder.descending || 
                      _currentSortOrder == _MarketsSortOrder.ascending) {
                    unawaited(_loadIndicatorValuesOnly());
                  } else {
                    unawaited(_loadVisibleItems());
                  }
                },
              );
            },
          ),
        ),
      ),
      body: Column(
        children: [
          // Indicator selector (always at top)
          if (_appState != null) IndicatorSelector(appState: _appState!),
          
          // Indicator settings
          Card(
            margin: const EdgeInsets.only(top: 8, bottom: 8),
            child: Column(
              children: [
                InkWell(
                  onTap: () {
                    if (mounted) {
                      setState(() {
                        _settingsExpanded = !_settingsExpanded;
                        // When expanding, fill fields with current values
                        if (_settingsExpanded) {
                          final indicatorType = _appState?.selectedIndicator ?? IndicatorType.rsi;
                          _indicatorPeriodController.text = _indicatorPeriod.toString();
                          _lowerLevelController.text = _lowerLevel.toStringAsFixed(0);
                          _upperLevelController.text = _upperLevel.toStringAsFixed(0);
                          if (indicatorType == IndicatorType.stoch && _stochDPeriod != null) {
                            _stochDPeriodController.text = _stochDPeriod.toString();
                          } else {
                            _stochDPeriodController.clear();
                          }
                        }
                      });
                    }
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Text(
                          loc.t('markets_indicator_settings'),
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
                        IntrinsicHeight(
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    () {
                                      final indicator = _appState?.selectedIndicator ?? IndicatorType.rsi;
                                      switch (indicator) {
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
                                    decoration: const InputDecoration(
                                      border: OutlineInputBorder(),
                                      isDense: true,
                                      contentPadding: EdgeInsets.symmetric(
                                          horizontal: 12, vertical: 8),
                                    ),
                                    keyboardType: TextInputType.number,
                                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9]'))],
                                  ),
                                ],
                              ),
                            ),
                            if (_appState?.selectedIndicator ==
                                IndicatorType.stoch) ...[
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      loc.t('home_stoch_d_period_label'),
                                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                                    ),
                                    const SizedBox(height: 4),
                                    TextField(
                                      controller: _stochDPeriodController,
                                      decoration: const InputDecoration(
                                        border: OutlineInputBorder(),
                                        isDense: true,
                                        contentPadding: EdgeInsets.symmetric(
                                            horizontal: 12, vertical: 8),
                                      ),
                                      keyboardType: TextInputType.number,
                                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9]'))],
                                    ),
                                  ],
                                ),
                              ),
                            ],
                            const SizedBox(width: 8),
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
                                    decoration: const InputDecoration(
                                      border: OutlineInputBorder(),
                                      isDense: true,
                                      contentPadding: EdgeInsets.symmetric(
                                          horizontal: 12, vertical: 8),
                                    ),
                                    keyboardType: TextInputType.numberWithOptions(signed: (_appState?.selectedIndicator ?? IndicatorType.rsi) == IndicatorType.williams),
                                    inputFormatters: (_appState?.selectedIndicator ?? IndicatorType.rsi) == IndicatorType.williams
                                        ? [WprLevelInputFormatter()]
                                        : [FilteringTextInputFormatter.allow(RegExp(r'[0-9]'))],
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
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
                                    decoration: const InputDecoration(
                                      border: OutlineInputBorder(),
                                      isDense: true,
                                      contentPadding: EdgeInsets.symmetric(
                                          horizontal: 12, vertical: 8),
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
                          children: [
                            IconButton(
                              icon: Icon(
                                () {
                                  switch (_currentSortOrder) {
                                    case _MarketsSortOrder.descending:
                                      return Icons.north;
                                    case _MarketsSortOrder.ascending:
                                      return Icons.south;
                                    case _MarketsSortOrder.marketCap:
                                      return Icons.unfold_more;
                                    case _MarketsSortOrder.none:
                                      return Icons.unfold_more; // Fallback
                                  }
                                }(),
                                color: () {
                                  switch (_currentSortOrder) {
                                    case _MarketsSortOrder.descending:
                                      return Colors.green;
                                    case _MarketsSortOrder.ascending:
                                      return Colors.red;
                                    case _MarketsSortOrder.marketCap:
                                      return Colors.grey[600];
                                    case _MarketsSortOrder.none:
                                      return Colors.grey[600]; // Fallback
                                  }
                                }(),
                              ),
                              tooltip: () {
                                switch (_currentSortOrder) {
                                  case _MarketsSortOrder.descending:
                                    return loc.t('watchlist_sort_desc');
                                  case _MarketsSortOrder.ascending:
                                    return loc.t('watchlist_sort_asc');
                                  case _MarketsSortOrder.marketCap:
                                    return 'Sort by Market Cap';
                                  case _MarketsSortOrder.none:
                                    return 'Sort by Market Cap'; // Fallback
                                }
                              }(),
                              onPressed: (_isLoading || _isActionInProgress)
                                  ? null
                                  : () {
                                      final currentSymbols = _getCurrentTabSymbols();
                                      if (currentSymbols.isEmpty) return;
                                      // Cycle: marketCap -> descending -> ascending -> marketCap
                                      final targetOrder = () {
                                        switch (_currentSortOrder) {
                                          case _MarketsSortOrder.marketCap:
                                            return _MarketsSortOrder.descending;
                                          case _MarketsSortOrder.descending:
                                            return _MarketsSortOrder.ascending;
                                          case _MarketsSortOrder.ascending:
                                            return _MarketsSortOrder.marketCap;
                                          case _MarketsSortOrder.none:
                                            return _MarketsSortOrder.marketCap; // Fallback
                                        }
                                      }();
                                      _applySortOrder(targetOrder);
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

          // Tab content
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildSymbolList(loc),
                _buildSymbolList(loc),
                _buildSymbolList(loc),
                _buildSymbolList(loc),
                _buildSymbolList(loc),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSymbolList(AppLocalizations loc) {
    if (_isLoading && _indicatorDataMap.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    final tabIndex = _tabController.index;
    final scrollController = _scrollControllers[tabIndex];
    // Get sorted symbols for current tab
    final symbols = _getCurrentTabSymbols();

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
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (indicatorData?.price != null) ...[
                    Text(
                      PriceFormatter.formatPrice(indicatorData!.price!),
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey[500],
                        fontWeight: FontWeight.normal,
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
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
            : SizedBox(
                height: 40,
                child: Center(
                  child: Text(
                    loc.t('error_no_data'),
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey[500],
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
              ),
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
  final double? price; // Last close price

  _SymbolIndicatorData({
    required this.currentValue,
    this.previousValue,
    required this.history,
    required this.timestamps,
    required this.indicatorResults,
    this.price,
  });
}
