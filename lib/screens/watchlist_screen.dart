import 'dart:async';
import 'package:flutter/material.dart';
import 'package:isar/isar.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models.dart';
import '../models/indicator_type.dart';
import '../services/yahoo_proto.dart';
import '../services/widget_service.dart';
import '../services/indicator_service.dart';
import '../widgets/indicator_chart.dart';
import '../localization/app_localizations.dart';
import '../services/data_sync_service.dart';
import '../services/auth_service.dart';
import '../services/alert_sync_service.dart';
import '../services/error_service.dart';
import '../state/app_state.dart';
import '../widgets/indicator_selector.dart';

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
  final Map<String, _SymbolIndicatorData> _indicatorDataMap = {};
  bool _isLoading = false;
  bool _settingsExpanded = false;
  bool _isActionInProgress = false;
  _RsiSortOrder _currentSortOrder = _RsiSortOrder.none;
  AppState? _appState; // App state for selected indicator

  // Settings for all charts
  String _timeframe = '15m';
  int _indicatorPeriod = 14;
  double _lowerLevel = 30.0;
  double _upperLevel = 70.0;
  IndicatorType? _previousIndicatorType; // Track previous indicator to save its settings
  int? _stochDPeriod; // Stochastic %D period (only for Stochastic)

  // Mass alert settings for all watchlist instruments (independent from view settings)
  // Store enabled state separately for each indicator
  final Map<IndicatorType, bool> _massAlertEnabledByIndicator = {
    IndicatorType.rsi: false,
    IndicatorType.stoch: false,
    IndicatorType.williams: false,
  };
  String _massAlertTimeframe = '15m'; // Independent timeframe for alerts
  // Mass alerts use the indicator selected in the main interface (via AppState)
  // No separate indicator selector needed
  int _massAlertPeriod = 14; // Independent period for alerts
  int? _massAlertStochDPeriod; // Independent %D period for Stochastic alerts
  String _massAlertMode = 'cross'; // cross|enter|exit
  double _massAlertLowerLevel = 30.0;
  double _massAlertUpperLevel = 70.0;
  bool _massAlertLowerLevelEnabled = true;
  bool _massAlertUpperLevelEnabled = true;
  int _massAlertCooldownSec = 600;
  bool _massAlertRepeatable = true;
  
  // Helper getter for current indicator (from AppState)
  IndicatorType get _massAlertIndicator => _appState?.selectedIndicator ?? IndicatorType.rsi;
  
  // Helper getter for current indicator's enabled state
  bool get _massAlertEnabled => _massAlertEnabledByIndicator[_massAlertIndicator] ?? false;
  
  // Helper setter for current indicator's enabled state
  set _massAlertEnabled(bool value) {
    _massAlertEnabledByIndicator[_massAlertIndicator] = value;
  }

  // Controllers for settings input fields
  final TextEditingController _indicatorPeriodController =
      TextEditingController();
  final TextEditingController _lowerLevelController = TextEditingController();
  final TextEditingController _upperLevelController = TextEditingController();
  final TextEditingController _stochDPeriodController = TextEditingController();

  // Controllers for mass alert settings
  final TextEditingController _massAlertPeriodController =
      TextEditingController();
  final TextEditingController _massAlertStochDPeriodController =
      TextEditingController();
  final TextEditingController _massAlertLowerLevelController =
      TextEditingController();
  final TextEditingController _massAlertUpperLevelController =
      TextEditingController();

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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _appState = AppStateScope.of(context);
    _previousIndicatorType = _appState?.selectedIndicator;
    _appState?.addListener(_onIndicatorChanged);
  }

  void _onIndicatorChanged() async {
    if (_appState != null) {
      final prefs = await SharedPreferences.getInstance();
      final indicatorType = _appState!.selectedIndicator;
      
      // Save current settings for the PREVIOUS indicator before switching
      if (_previousIndicatorType != null && _previousIndicatorType != indicatorType) {
        // Save view settings
        await prefs.setInt(
          'watchlist_${_previousIndicatorType!.toJson()}_period',
          _indicatorPeriod,
        );
        await prefs.setDouble(
          'watchlist_${_previousIndicatorType!.toJson()}_lower_level',
          _lowerLevel,
        );
        await prefs.setDouble(
          'watchlist_${_previousIndicatorType!.toJson()}_upper_level',
          _upperLevel,
        );
        if (_previousIndicatorType == IndicatorType.stoch && _stochDPeriod != null) {
          await prefs.setInt('watchlist_stoch_d_period', _stochDPeriod!);
        }
        
        // Save mass alert settings for the previous indicator
        final previousIndicatorKey = _previousIndicatorType!.toJson();
        await prefs.setInt('watchlist_mass_alert_${previousIndicatorKey}_period', _massAlertPeriod);
        await prefs.setDouble('watchlist_mass_alert_${previousIndicatorKey}_lower_level', _massAlertLowerLevel);
        await prefs.setDouble('watchlist_mass_alert_${previousIndicatorKey}_upper_level', _massAlertUpperLevel);
        await prefs.setBool('watchlist_mass_alert_${previousIndicatorKey}_lower_level_enabled', _massAlertLowerLevelEnabled);
        await prefs.setBool('watchlist_mass_alert_${previousIndicatorKey}_upper_level_enabled', _massAlertUpperLevelEnabled);
      }

      // Load saved view settings for the new indicator, or use defaults
      // IMPORTANT: Always use defaults if no saved settings exist, don't use current values
      final savedPeriod = prefs.getInt('watchlist_${indicatorType.toJson()}_period');
      final savedLowerLevel = prefs.getDouble('watchlist_${indicatorType.toJson()}_lower_level');
      final savedUpperLevel = prefs.getDouble('watchlist_${indicatorType.toJson()}_upper_level');
      
      // Load saved mass alert settings for the new indicator, or use defaults
      final savedMassAlertPeriod = prefs.getInt('watchlist_mass_alert_${indicatorType.toJson()}_period');
      final savedMassAlertLowerLevel = prefs.getDouble('watchlist_mass_alert_${indicatorType.toJson()}_lower_level');
      final savedMassAlertUpperLevel = prefs.getDouble('watchlist_mass_alert_${indicatorType.toJson()}_upper_level');
      
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
            _stochDPeriod = prefs.getInt('watchlist_stoch_d_period') ?? 3;
          } else {
            _stochDPeriod = null;
          }
          
          // Load mass alert settings for the new indicator
          _massAlertPeriod = savedMassAlertPeriod ?? indicatorType.defaultPeriod;
          // Validate mass alert levels
          final massAlertLowerValid = savedMassAlertLowerLevel != null &&
              ((indicatorType == IndicatorType.williams && savedMassAlertLowerLevel >= -100.0 && savedMassAlertLowerLevel <= 0.0) ||
               (indicatorType != IndicatorType.williams && savedMassAlertLowerLevel >= 0.0 && savedMassAlertLowerLevel <= 100.0));
          final massAlertUpperValid = savedMassAlertUpperLevel != null &&
              ((indicatorType == IndicatorType.williams && savedMassAlertUpperLevel >= -100.0 && savedMassAlertUpperLevel <= 0.0) ||
               (indicatorType != IndicatorType.williams && savedMassAlertUpperLevel >= 0.0 && savedMassAlertUpperLevel <= 100.0));
          _massAlertLowerLevel = massAlertLowerValid ? savedMassAlertLowerLevel : indicatorType.defaultLevels.first;
          _massAlertUpperLevel = massAlertUpperValid ? savedMassAlertUpperLevel :
              (indicatorType.defaultLevels.length > 1
                  ? indicatorType.defaultLevels[1]
                  : (indicatorType == IndicatorType.williams ? 0.0 : 100.0));
          
          // Load level enabled state
          final indicatorKey = indicatorType.toJson();
          final savedLowerEnabled = prefs.getBool('watchlist_mass_alert_${indicatorKey}_lower_level_enabled');
          final savedUpperEnabled = prefs.getBool('watchlist_mass_alert_${indicatorKey}_upper_level_enabled');
          _massAlertLowerLevelEnabled = savedLowerEnabled ?? true;
          _massAlertUpperLevelEnabled = savedUpperEnabled ?? true;
          
          if (indicatorType == IndicatorType.stoch) {
            _massAlertStochDPeriod = prefs.getInt('watchlist_mass_alert_stoch_d_period') ?? 3;
          } else {
            _massAlertStochDPeriod = null;
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
          
          // Update mass alert controllers
          _massAlertPeriodController.text = _massAlertPeriod.toString();
          if (_massAlertStochDPeriod != null) {
            _massAlertStochDPeriodController.text = _massAlertStochDPeriod.toString();
          } else {
            _massAlertStochDPeriodController.clear();
          }
          _massAlertLowerLevelController.text = _massAlertLowerLevel.toStringAsFixed(0);
          _massAlertUpperLevelController.text = _massAlertUpperLevel.toStringAsFixed(0);
        });
      }

      // Update previous indicator type AFTER loading new settings
      _previousIndicatorType = indicatorType;

      // Save loaded settings so widget can use them
      await _saveState();

      // Update widget with new indicator
      final indicatorParams =
          indicatorType == IndicatorType.stoch && _stochDPeriod != null
              ? {'dPeriod': _stochDPeriod}
              : null;
      unawaited(_widgetService.updateWidget(
        timeframe: _timeframe,
        rsiPeriod: _indicatorPeriod,
        sortDescending: _currentSortOrder != _RsiSortOrder.ascending,
        indicator: indicatorType,
        indicatorParams: indicatorParams,
      ));

      // Clear data and reload when indicator changes
      if (mounted) {
        setState(() {
          _indicatorDataMap.clear();
        });
      }
      _loadAllIndicatorData();
    }
  }

  Future<void> _updateWidgetOrder(bool sortDescending) async {
    try {
      final indicatorType = _appState?.selectedIndicator ?? IndicatorType.rsi;
      final indicatorParams =
          indicatorType == IndicatorType.stoch && _stochDPeriod != null
              ? {'dPeriod': _stochDPeriod}
              : null;
      await _widgetService.updateWidget(
        timeframe: _timeframe,
        rsiPeriod: _indicatorPeriod,
        sortDescending: sortDescending,
        indicator: indicatorType,
        indicatorParams: indicatorParams,
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
      final value = _indicatorDataMap[symbol]?.currentIndicatorValue;
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

    if (mounted) {
      setState(() {
        // Use widget settings if available, otherwise use watchlist settings
        _timeframe = widgetTimeframe ?? watchlistTimeframe ?? '15m';
        final indicatorType = _appState?.selectedIndicator ?? IndicatorType.rsi;
        _indicatorPeriod =
            widgetPeriod ?? watchlistPeriod ?? indicatorType.defaultPeriod;
        _lowerLevel = prefs.getDouble('watchlist_${indicatorType.toJson()}_lower_level') ??
            indicatorType.defaultLevels.first;
        _upperLevel = prefs.getDouble('watchlist_${indicatorType.toJson()}_upper_level') ??
            (indicatorType.defaultLevels.length > 1
                ? indicatorType.defaultLevels[1]
                : 100.0);
        
        // For Stochastic, load saved %D period or use default
        if (indicatorType == IndicatorType.stoch) {
          _stochDPeriod = prefs.getInt('watchlist_stoch_d_period') ?? 3;
        } else {
          _stochDPeriod = null;
        }
        
        // Load saved sort order, fallback to widget sort order if available
        final savedSortOrder = prefs.getString(_sortOrderPrefKey);
        final widgetSortDescending = prefs.getBool('rsi_widget_sort_descending');
        if (savedSortOrder != null) {
          _currentSortOrder = _sortOrderFromString(savedSortOrder);
        } else if (widgetSortDescending != null) {
          _currentSortOrder = widgetSortDescending
              ? _RsiSortOrder.descending
              : _RsiSortOrder.ascending;
        } else {
          _currentSortOrder = _RsiSortOrder.none;
        }

        // Load mass alert settings (independent from view settings)
        // Load enabled state for each indicator separately
        _massAlertEnabledByIndicator[IndicatorType.rsi] =
            prefs.getBool('watchlist_mass_alert_rsi_enabled') ?? false;
        _massAlertEnabledByIndicator[IndicatorType.stoch] =
            prefs.getBool('watchlist_mass_alert_stoch_enabled') ?? false;
        _massAlertEnabledByIndicator[IndicatorType.williams] =
            prefs.getBool('watchlist_mass_alert_williams_enabled') ?? false;
        
        _massAlertTimeframe =
            prefs.getString('watchlist_mass_alert_timeframe') ?? _timeframe;
        // Mass alerts use the indicator from AppState (main interface)
        // Load settings for the current indicator from AppState
        final indicatorKey = indicatorType.toJson();
        _massAlertPeriod = prefs.getInt('watchlist_mass_alert_${indicatorKey}_period') ??
            indicatorType.defaultPeriod;
        _massAlertStochDPeriod =
            prefs.getInt('watchlist_mass_alert_stoch_d_period');
        if (indicatorType == IndicatorType.stoch &&
            _massAlertStochDPeriod == null) {
          _massAlertStochDPeriod = 3;
        }
        _massAlertMode = prefs.getString('watchlist_mass_alert_mode') ?? 'cross';
        final savedMassAlertLower = prefs.getDouble('watchlist_mass_alert_${indicatorKey}_lower_level');
        final savedMassAlertUpper = prefs.getDouble('watchlist_mass_alert_${indicatorKey}_upper_level');
        // Validate mass alert levels
        final massAlertLowerValid = savedMassAlertLower != null &&
            ((indicatorType == IndicatorType.williams && savedMassAlertLower >= -100.0 && savedMassAlertLower <= 0.0) ||
             (indicatorType != IndicatorType.williams && savedMassAlertLower >= 0.0 && savedMassAlertLower <= 100.0));
        final massAlertUpperValid = savedMassAlertUpper != null &&
            ((indicatorType == IndicatorType.williams && savedMassAlertUpper >= -100.0 && savedMassAlertUpper <= 0.0) ||
             (indicatorType != IndicatorType.williams && savedMassAlertUpper >= 0.0 && savedMassAlertUpper <= 100.0));
        _massAlertLowerLevel = massAlertLowerValid ? savedMassAlertLower : indicatorType.defaultLevels.first;
        _massAlertUpperLevel = massAlertUpperValid ? savedMassAlertUpper :
            (indicatorType.defaultLevels.length > 1
                ? indicatorType.defaultLevels[1]
                : (indicatorType == IndicatorType.williams ? 0.0 : 100.0));
        _massAlertCooldownSec =
            prefs.getInt('watchlist_mass_alert_cooldown_sec') ?? 600;
        _massAlertRepeatable =
            prefs.getBool('watchlist_mass_alert_repeatable') ?? true;
        
        // Load level enabled state (if not saved, check existing alerts to determine state)
        final savedLowerEnabled = prefs.getBool('watchlist_mass_alert_${indicatorKey}_lower_level_enabled');
        final savedUpperEnabled = prefs.getBool('watchlist_mass_alert_${indicatorKey}_upper_level_enabled');
        
        if (savedLowerEnabled != null && savedUpperEnabled != null) {
          // Use saved state
          _massAlertLowerLevelEnabled = savedLowerEnabled;
          _massAlertUpperLevelEnabled = savedUpperEnabled;
        } else {
          // Try to sync with existing alerts (if mass alerts are enabled)
          if (_massAlertEnabledByIndicator[indicatorType] == true) {
            // This will be synced after watchlist items are loaded
            // For now, use defaults (both enabled)
            _massAlertLowerLevelEnabled = true;
            _massAlertUpperLevelEnabled = true;
          } else {
            // Defaults
            _massAlertLowerLevelEnabled = true;
            _massAlertUpperLevelEnabled = true;
          }
        }

        // Initialize mass alert controllers
        _massAlertPeriodController.text = _massAlertPeriod.toString();
        if (_massAlertStochDPeriod != null) {
          _massAlertStochDPeriodController.text =
              _massAlertStochDPeriod.toString();
        }
        _massAlertLowerLevelController.text =
            _massAlertLowerLevel.toStringAsFixed(0);
        _massAlertUpperLevelController.text =
            _massAlertUpperLevel.toStringAsFixed(0);
      });
    }

    // Save period and timeframe for widget to ensure consistency
    final indicatorType = _appState?.selectedIndicator ?? IndicatorType.rsi;
    await prefs.setInt('rsi_widget_period', _indicatorPeriod);
    await prefs.setString('rsi_widget_timeframe', _timeframe);
    // Also save to watchlist settings for consistency
    await prefs.setInt(
        'watchlist_${indicatorType.toJson()}_period', _indicatorPeriod);
    await prefs.setString('watchlist_timeframe', _timeframe);

    _loadWatchlist();
  }

  Future<void> _saveState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('watchlist_timeframe', _timeframe);
    final indicatorType = _appState?.selectedIndicator ?? IndicatorType.rsi;
    await prefs.setInt(
        'watchlist_${indicatorType.toJson()}_period', _indicatorPeriod);
    await prefs.setDouble('watchlist_${indicatorType.toJson()}_lower_level', _lowerLevel);
    await prefs.setDouble('watchlist_${indicatorType.toJson()}_upper_level', _upperLevel);
    if (indicatorType == IndicatorType.stoch && _stochDPeriod != null) {
      await prefs.setInt('watchlist_stoch_d_period', _stochDPeriod!);
    }
    // Also save to widget settings to keep them in sync
    await prefs.setInt('rsi_widget_period', _indicatorPeriod);
    await prefs.setString('rsi_widget_timeframe', _timeframe);

    // Save mass alert settings (independent from view settings)
    // Save enabled state for each indicator separately
    await prefs.setBool('watchlist_mass_alert_rsi_enabled', _massAlertEnabledByIndicator[IndicatorType.rsi] ?? false);
    await prefs.setBool('watchlist_mass_alert_stoch_enabled', _massAlertEnabledByIndicator[IndicatorType.stoch] ?? false);
    await prefs.setBool('watchlist_mass_alert_williams_enabled', _massAlertEnabledByIndicator[IndicatorType.williams] ?? false);
    
    await prefs.setString(
        'watchlist_mass_alert_timeframe', _massAlertTimeframe);
    // Mass alerts use the indicator from AppState (main interface)
    // Save settings for the current indicator from AppState
    final indicatorKey = indicatorType.toJson();
    await prefs.setInt('watchlist_mass_alert_${indicatorKey}_period', _massAlertPeriod);
    if (_massAlertStochDPeriod != null) {
      await prefs.setInt(
          'watchlist_mass_alert_stoch_d_period', _massAlertStochDPeriod!);
    } else {
      await prefs.remove('watchlist_mass_alert_stoch_d_period');
    }
    await prefs.setString('watchlist_mass_alert_mode', _massAlertMode);
    await prefs.setDouble(
        'watchlist_mass_alert_${indicatorKey}_lower_level', _massAlertLowerLevel);
    await prefs.setDouble(
        'watchlist_mass_alert_${indicatorKey}_upper_level', _massAlertUpperLevel);
    await prefs.setBool(
        'watchlist_mass_alert_${indicatorKey}_lower_level_enabled', _massAlertLowerLevelEnabled);
    await prefs.setBool(
        'watchlist_mass_alert_${indicatorKey}_upper_level_enabled', _massAlertUpperLevelEnabled);
    await prefs.setInt(
        'watchlist_mass_alert_cooldown_sec', _massAlertCooldownSec);
    await prefs.setBool(
        'watchlist_mass_alert_repeatable', _massAlertRepeatable);
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
    if (widgetPeriod != null) {
      setState(() {
        _indicatorPeriod = widgetPeriod;
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
      _loadAllIndicatorData();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _indicatorPeriodController.dispose();
    _lowerLevelController.dispose();
    _upperLevelController.dispose();
    _stochDPeriodController.dispose();
    _massAlertPeriodController.dispose();
    _massAlertStochDPeriodController.dispose();
    _massAlertLowerLevelController.dispose();
    _massAlertUpperLevelController.dispose();
    super.dispose();
  }

  void _updateControllerHints() {
    _indicatorPeriodController.clear();
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
          _indicatorDataMap.clear();
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

      // Load indicator data for all symbols
      await _loadAllIndicatorData();

      // Update widget after loading watchlist (use current watchlist settings)
      final indicatorType = _appState?.selectedIndicator ?? IndicatorType.rsi;
      final indicatorParams =
          indicatorType == IndicatorType.stoch && _stochDPeriod != null
              ? {'dPeriod': _stochDPeriod}
              : null;
      unawaited(_widgetService.updateWidget(
        timeframe: _timeframe,
        rsiPeriod: _indicatorPeriod,
        sortDescending: _currentSortOrder != _RsiSortOrder.ascending,
        indicator: indicatorType,
        indicatorParams: indicatorParams,
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

  Future<void> _loadAllIndicatorData() async {
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
          batch.map((symbol) => _loadIndicatorDataForSymbol(symbol)),
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
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
      // Update widget after loading data (use current watchlist settings)
      final indicatorType = _appState?.selectedIndicator ?? IndicatorType.rsi;
      final indicatorParams =
          indicatorType == IndicatorType.stoch && _stochDPeriod != null
              ? {'dPeriod': _stochDPeriod}
              : null;
      unawaited(_widgetService.updateWidget(
        timeframe: _timeframe,
        rsiPeriod: _indicatorPeriod,
        sortDescending: _currentSortOrder != _RsiSortOrder.ascending,
        indicator: indicatorType,
        indicatorParams: indicatorParams,
      ));
    }
  }

  Future<void> _loadIndicatorDataForSymbol(String symbol) async {
    const maxRetries = 3;
    int attempt = 0;
    final indicatorType = _appState?.selectedIndicator ?? IndicatorType.rsi;

    while (attempt < maxRetries) {
      try {
        // Optimized limits based on actual usage (calculation needs + chart display)
        // RSI/Stochastic/Williams need max ~112 candles for period=100, charts show 50 points
        int limit = 120; // For 1m, 5m, 15m, 1h - sufficient for calculation + chart (50 points)
        if (_timeframe == '4h') {
          limit = 180; // For 4h - sufficient for calculation + chart (50 points)
        } else if (_timeframe == '1d') {
          limit = 180; // For 1d - sufficient for calculation + chart (50 points)
        }

        final candles = await _yahooService.fetchCandles(
          symbol,
          _timeframe,
          limit: limit,
        );

        if (candles.isEmpty) {
          if (mounted) {
            setState(() {
              _indicatorDataMap[symbol] = _SymbolIndicatorData(
                currentIndicatorValue: 0.0,
                indicatorValues: [],
                timestamps: [],
                indicatorResults: [],
              );
            });
          }
          return;
        }

        // Convert candles to format expected by IndicatorService
        final candlesList = candles
            .map((c) => {
                  'open': c.open,
                  'high': c.high,
                  'low': c.low,
                  'close': c.close,
                  'timestamp': c.timestamp,
                })
            .toList();

        // Prepare indicator parameters
        Map<String, dynamic>? indicatorParams;
        if (indicatorType == IndicatorType.stoch) {
          indicatorParams = {'dPeriod': _stochDPeriod ?? 3};
        }

        // Check minimum data required
        final minDataRequired = indicatorType == IndicatorType.stoch
            ? _indicatorPeriod + (_stochDPeriod ?? 3) - 1
            : _indicatorPeriod + 1;

        if (candles.length < minDataRequired) {
          if (mounted) {
            setState(() {
              _indicatorDataMap[symbol] = _SymbolIndicatorData(
                currentIndicatorValue: 0.0,
                indicatorValues: [],
                timestamps: [],
                indicatorResults: [],
              );
            });
          }
          return;
        }

        // Calculate indicator using IndicatorService
        final indicatorResults = IndicatorService.calculateIndicatorHistory(
          candlesList,
          indicatorType,
          _indicatorPeriod,
          indicatorParams,
        );

        if (indicatorResults.isEmpty) {
          if (mounted) {
            setState(() {
              _indicatorDataMap[symbol] = _SymbolIndicatorData(
                currentIndicatorValue: 0.0,
                indicatorValues: [],
                timestamps: [],
                indicatorResults: [],
              );
            });
          }
          return;
        }

        // Extract values and timestamps
        final indicatorValues = indicatorResults.map((r) => r.value).toList();
        final indicatorTimestamps =
            indicatorResults.map((r) => r.timestamp).toList();

        // Take only last 50 points for compact chart
        final chartIndicatorValues = indicatorValues.length > 50
            ? indicatorValues.sublist(indicatorValues.length - 50)
            : indicatorValues;
        final chartIndicatorTimestamps = indicatorTimestamps.length > 50
            ? indicatorTimestamps.sublist(indicatorTimestamps.length - 50)
            : indicatorTimestamps;
        final chartIndicatorResults = indicatorResults.length > 50
            ? indicatorResults.sublist(indicatorResults.length - 50)
            : indicatorResults;

        // Get last close price
        final lastPrice = candles.isNotEmpty ? candles.last.close : null;

        if (mounted) {
          setState(() {
            _indicatorDataMap[symbol] = _SymbolIndicatorData(
              currentIndicatorValue:
                  indicatorValues.isNotEmpty ? indicatorValues.last : 0.0,
              indicatorValues: chartIndicatorValues,
              timestamps: chartIndicatorTimestamps,
              indicatorResults: chartIndicatorResults,
              price: lastPrice,
            );
          });
        }
        return; // Success, exit retry loop
      } catch (e) {
        attempt++;
        debugPrint(
            'Error loading indicator for $symbol (attempt $attempt/$maxRetries): $e');

        // Log error to server (only on final attempt to avoid spam)
        if (attempt >= maxRetries) {
          ErrorService.logError(
            error: e,
            context: 'watchlist_screen_load_indicator',
            symbol: symbol,
            timeframe: _timeframe,
            additionalData: {'attempt': attempt.toString()},
          );
        }

        if (attempt >= maxRetries) {
          // All retries failed, set empty data
          debugPrint(
              'Failed to load indicator for $symbol after $maxRetries attempts');
          if (mounted) {
            setState(() {
              _indicatorDataMap[symbol] = _SymbolIndicatorData(
                currentIndicatorValue: 0.0,
                indicatorValues: [],
                timestamps: [],
                indicatorResults: [],
              );
            });
          }
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
    if (mounted) {
      setState(() {
        _watchlistItems.remove(item);
        _indicatorDataMap.remove(item.symbol);
      });
    }
    // Sync watchlist: to server if authenticated, to cache if anonymous
    if (AuthService.isSignedIn) {
      unawaited(DataSyncService.syncWatchlist(widget.isar));
    } else {
      unawaited(DataSyncService.saveWatchlistToCache(widget.isar));
    }
    // Update widget after deletion
    final indicatorType = _appState?.selectedIndicator ?? IndicatorType.rsi;
    final indicatorParams =
        indicatorType == IndicatorType.stoch && _stochDPeriod != null
            ? {'dPeriod': _stochDPeriod}
            : null;
    unawaited(_widgetService.updateWidget(
      timeframe: _timeframe,
      rsiPeriod: _indicatorPeriod,
      sortDescending: _currentSortOrder != _RsiSortOrder.ascending,
      indicator: indicatorType,
      indicatorParams: indicatorParams,
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
      final period = int.tryParse(_indicatorPeriodController.text);
      final lower = int.tryParse(_lowerLevelController.text)?.toDouble();
      final upper = int.tryParse(_upperLevelController.text)?.toDouble();

      bool changed = false;

      if (period != null &&
          period >= 2 &&
          period <= 100 &&
          period != _indicatorPeriod) {
        _indicatorPeriod = period;
        changed = true;
        _saveState();
      }

      // Validate levels based on indicator type
      final indicatorType = _appState?.selectedIndicator ?? IndicatorType.rsi;
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

      _updateControllerHints();

      if (changed) {
        // Save period for widget
        if (period != null) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setInt('rsi_widget_period', _indicatorPeriod);
        }
        _loadAllIndicatorData();
        // Update widget with new period
        final indicatorType = _appState?.selectedIndicator ?? IndicatorType.rsi;
        final indicatorParams =
            indicatorType == IndicatorType.stoch && _stochDPeriod != null
                ? {'dPeriod': _stochDPeriod}
                : null;
        unawaited(_widgetService.updateWidget(
          rsiPeriod: _indicatorPeriod,
          sortDescending: _currentSortOrder != _RsiSortOrder.ascending,
          indicator: indicatorType,
          indicatorParams: indicatorParams,
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
      final indicatorType = _appState?.selectedIndicator ?? IndicatorType.rsi;
      setState(() {
        _timeframe = '15m';
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
      // Save period for widget
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('rsi_widget_period', _indicatorPeriod);
      _updateControllerHints();
      _loadAllIndicatorData();
      // Update widget
      final indicatorParams =
          indicatorType == IndicatorType.stoch && _stochDPeriod != null
              ? {'dPeriod': _stochDPeriod}
              : null;
      unawaited(_widgetService.updateWidget(
        timeframe: _timeframe,
        rsiPeriod: _indicatorPeriod,
        sortDescending: _currentSortOrder != _RsiSortOrder.ascending,
        indicator: indicatorType,
        indicatorParams: indicatorParams,
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
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        title: Text(loc.t('watchlist_title')),
        backgroundColor: Colors.blue[900],
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          // Indicator selector (always at top, fixed)
          if (_appState != null) IndicatorSelector(appState: _appState!),
          
          // Collapsible settings bar (fixed)
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
                        _indicatorPeriodController.text =
                            _indicatorPeriod.toString();
                        _lowerLevelController.text =
                            _lowerLevel.toStringAsFixed(0);
                        _upperLevelController.text =
                            _upperLevel.toStringAsFixed(0);
                        if (_stochDPeriod != null) {
                          _stochDPeriodController.text =
                              _stochDPeriod.toString();
                        } else {
                          _stochDPeriodController.clear();
                        }
                      }
                    });
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
                                flex: 2,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      loc.t('home_timeframe_label'),
                                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                                    ),
                                    const Spacer(),
                                    DropdownButtonFormField<String>(
                                      initialValue: _timeframe,
                                      decoration: const InputDecoration(
                                        border: OutlineInputBorder(),
                                        isDense: true,
                                        contentPadding: EdgeInsets.symmetric(
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
                                          'rsi_widget_period', _indicatorPeriod);
                                      _loadAllIndicatorData(); // Automatically reload data when timeframe changes
                                      // Update widget
                                      final indicatorType =
                                          _appState?.selectedIndicator ??
                                              IndicatorType.rsi;
                                      final indicatorParams =
                                          indicatorType == IndicatorType.stoch &&
                                                  _stochDPeriod != null
                                              ? {'dPeriod': _stochDPeriod}
                                              : null;
                                      unawaited(_widgetService.updateWidget(
                                        timeframe: _timeframe,
                                        rsiPeriod: _indicatorPeriod,
                                        sortDescending: _currentSortOrder !=
                                            _RsiSortOrder.ascending,
                                        indicator: indicatorType,
                                        indicatorParams: indicatorParams,
                                      ));
                                    }
                                      },
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
                                      const Spacer(),
                                      TextField(
                                        key: ValueKey('stoch_d_period_${_stochDPeriod ?? 0}'),
                                        controller: _stochDPeriodController,
                                        decoration: const InputDecoration(
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
                                          }
                                        },
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
                                      keyboardType: TextInputType.number,
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
                                      keyboardType: TextInputType.number,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
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
          
          // Mass alerts section (always visible as separate block, fixed)
          _buildMassAlertsSection(context),

          // Watchlist counter (e.g., "23/30") (fixed)
          Padding(
            padding: const EdgeInsets.only(left: 16, top: 4, bottom: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '${_watchlistItems.length}/30',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey[600],
                ),
              ),
            ),
          ),

          // Scrollable instruments list
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

                                    final indicatorData =
                                        _indicatorDataMap[item.symbol] ??
                                            _SymbolIndicatorData(
                                              currentIndicatorValue: 0.0,
                                              indicatorValues: [],
                                              timestamps: [],
                                              indicatorResults: [],
                                            );

                                    return _buildWatchlistItem(
                                        item, indicatorData);
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

  Widget _buildWatchlistItem(
      WatchlistItem item, _SymbolIndicatorData indicatorData) {
    final loc = context.loc;
    final indicatorType = _appState?.selectedIndicator ?? IndicatorType.rsi;
    final currentValue = indicatorData.currentIndicatorValue;
    final zone = IndicatorService.getIndicatorZone(
      currentValue,
      [_lowerLevel, _upperLevel],
      indicatorType,
    );
    final indicatorColor = IndicatorService.getZoneColor(zone, indicatorType);

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
                  Row(
                    children: [
                      if (indicatorData.price != null) ...[
                        Text(
                          indicatorData.price!.toStringAsFixed(2),
                          style: TextStyle(
                            fontSize: 9,
                            color: Colors.grey[500],
                            fontWeight: FontWeight.normal,
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                      Text(
                        '${indicatorType.name}: ${currentValue.toStringAsFixed(1)}',
                        style: TextStyle(
                          fontSize: 11,
                          color: indicatorColor,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 4),
              if (indicatorData.indicatorValues.isNotEmpty)
                SizedBox(
                  height: 53, // Increased from 50 to 53 (approximately 5%)
                  child: IndicatorChart(
                    indicatorResults: indicatorData.indicatorResults,
                    timestamps: indicatorData.timestamps,
                    indicatorType: indicatorType,
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

  Widget _buildMassAlertsSection(BuildContext context) {
    final loc = context.loc;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: ExpansionTile(
        title: Row(
          children: [
            const Icon(Icons.notifications_active, size: 20),
            const SizedBox(width: 8),
            Text(
              'Watchlist Alert',
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        subtitle: _massAlertEnabled
            ? Text(
                '${_watchlistItems.length} instruments (${_massAlertIndicator.name.toUpperCase()})',
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.green,
                ),
              )
            : null,
        leading: Switch(
          value: _massAlertEnabled,
          onChanged: (value) async {
            setState(() {
              _massAlertEnabled = value; // Uses the setter which updates the map
            });
            await _saveState();
            if (value) {
              await _createMassAlerts();
            } else {
              // Deactivate mass alerts for THIS INDICATOR only
              await _deleteMassAlerts();
            }
          },
        ),
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: SingleChildScrollView(
              physics: const ClampingScrollPhysics(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                // Timeframe for alerts
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      loc.t('home_timeframe_label'),
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    const SizedBox(height: 4),
                    DropdownButtonFormField<String>(
                      value: _massAlertTimeframe,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                      ),
                  items: const [
                    DropdownMenuItem(value: '1m', child: Text('1m')),
                    DropdownMenuItem(value: '5m', child: Text('5m')),
                    DropdownMenuItem(value: '15m', child: Text('15m')),
                    DropdownMenuItem(value: '1h', child: Text('1h')),
                    DropdownMenuItem(value: '4h', child: Text('4h')),
                    DropdownMenuItem(value: '1d', child: Text('1d')),
                  ],
                  onChanged: (value) async {
                    if (value != null && value != _massAlertTimeframe) {
                      debugPrint('Mass alert timeframe changed from $_massAlertTimeframe to $value, enabled: $_massAlertEnabled');
                      setState(() {
                        _massAlertTimeframe = value;
                      });
                      await _saveState();
                      if (_massAlertEnabled) {
                        debugPrint('Calling _updateMassAlerts after timeframe change');
                        await _updateMassAlerts();
                      } else {
                        debugPrint('Mass alert not enabled, skipping update');
                      }
                    }
                      },
                    ),
                  ],
                ),
                // Note: Mass alerts use the indicator selected in the main interface (via IndicatorSelector above)
                const SizedBox(height: 16),
                // Period for alerts
                            IntrinsicHeight(
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            () {
                              final indicator = _massAlertIndicator;
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
                            controller: _massAlertPeriodController,
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                              isDense: true,
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                            ),
                            keyboardType: TextInputType.number,
                            onChanged: (value) {
                              final period = int.tryParse(value);
                              if (period != null && period >= 1 && period <= 100 && period != _massAlertPeriod) {
                                setState(() {
                                  _massAlertPeriod = period;
                                });
                                _saveState();
                                if (_massAlertEnabled) {
                                  unawaited(_updateMassAlerts());
                                }
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                    if (_massAlertIndicator == IndicatorType.stoch) ...[
                      const SizedBox(width: 8),
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
                              controller: _massAlertStochDPeriodController,
                              decoration: const InputDecoration(
                                border: OutlineInputBorder(),
                                isDense: true,
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                              ),
                              keyboardType: TextInputType.number,
                              onChanged: (value) {
                                final dPeriod = int.tryParse(value);
                                if (dPeriod != null &&
                                    dPeriod >= 1 &&
                                    dPeriod <= 100 &&
                                    dPeriod != _massAlertStochDPeriod) {
                                  setState(() {
                                    _massAlertStochDPeriod = dPeriod;
                                  });
                                  _saveState();
                                  if (_massAlertEnabled) {
                                    unawaited(_updateMassAlerts());
                                  }
                                }
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
                const SizedBox(height: 16),
                // Levels
                Text(
                  loc.t('create_alert_levels_title'),
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 8),
                IntrinsicHeight(
                  child: Row(
                    children: [
                      Checkbox(
                        value: _massAlertLowerLevelEnabled,
                      onChanged: (value) {
                        if (value == false && !_massAlertUpperLevelEnabled) {
                          // Prevent disabling both levels
                          return;
                        }
                        setState(() {
                          _massAlertLowerLevelEnabled = value ?? true;
                        });
                        _saveState();
                        if (_massAlertEnabled) {
                          unawaited(_updateMassAlerts());
                        }
                      },
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            () {
                              final indicator = _massAlertIndicator;
                              switch (indicator) {
                                case IndicatorType.williams:
                                  return loc.t('home_wpr_lower_level_label');
                                case IndicatorType.stoch:
                                  return loc.t('home_stoch_lower_level_label');
                                case IndicatorType.rsi:
                                  return loc.t('create_alert_lower_level');
                              }
                            }(),
                            style: const TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                          const Spacer(),
                          TextField(
                            controller: _massAlertLowerLevelController,
                            enabled: _massAlertLowerLevelEnabled,
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                              isDense: true,
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                            ),
                            keyboardType: TextInputType.number,
                            onChanged: (value) {
                              final lower = int.tryParse(value)?.toDouble();
                              if (lower == null) return;
                              
                              bool isValid = false;
                              if (_massAlertIndicator == IndicatorType.williams) {
                                // WPR: -99 to -1
                                isValid = lower >= -99 && lower <= -1;
                              } else {
                                // RSI/STOCH: 1 to 99
                                isValid = lower >= 1 && lower <= 99;
                              }
                              
                              // Check that lower level is below upper level (if both enabled)
                              if (isValid && _massAlertUpperLevelEnabled && lower >= _massAlertUpperLevel) {
                                return; // Lower level cannot be above or equal to upper level
                              }
                              
                              if (isValid && lower != _massAlertLowerLevel) {
                                setState(() {
                                  _massAlertLowerLevel = lower;
                                });
                                _saveState();
                                if (_massAlertEnabled) {
                                  unawaited(_updateMassAlerts());
                                }
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Checkbox(
                      value: _massAlertUpperLevelEnabled,
                      onChanged: (value) {
                        if (value == false && !_massAlertLowerLevelEnabled) {
                          // Prevent disabling both levels
                          return;
                        }
                        setState(() {
                          _massAlertUpperLevelEnabled = value ?? true;
                        });
                        _saveState();
                        if (_massAlertEnabled) {
                          unawaited(_updateMassAlerts());
                        }
                      },
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            () {
                              final indicator = _massAlertIndicator;
                              switch (indicator) {
                                case IndicatorType.williams:
                                  return loc.t('home_wpr_upper_level_label');
                                case IndicatorType.stoch:
                                  return loc.t('home_stoch_upper_level_label');
                                case IndicatorType.rsi:
                                  return loc.t('create_alert_upper_level');
                              }
                            }(),
                            style: const TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                          const Spacer(),
                          TextField(
                            controller: _massAlertUpperLevelController,
                            enabled: _massAlertUpperLevelEnabled,
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                              isDense: true,
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                            ),
                            keyboardType: TextInputType.number,
                            onChanged: (value) {
                              final upper = int.tryParse(value)?.toDouble();
                              if (upper == null) return;
                              
                              bool isValid = false;
                              if (_massAlertIndicator == IndicatorType.williams) {
                                // WPR: -99 to -1, and upper must be greater than lower
                                isValid = upper >= -99 && upper <= -1 && upper > _massAlertLowerLevel;
                              } else {
                                // RSI/STOCH: 1 to 99, and upper must be greater than lower
                                isValid = upper >= 1 && upper <= 99 && upper > _massAlertLowerLevel;
                              }
                              
                              if (isValid && upper != _massAlertUpperLevel) {
                                setState(() {
                                  _massAlertUpperLevel = upper;
                                });
                                _saveState();
                                if (_massAlertEnabled) {
                                  unawaited(_updateMassAlerts());
                                }
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                  ),
                ),
            ],
          ),
          ),
        ),
        ],
      ),
    );
  }

  Future<void> _createMassAlerts() async {
    if (_watchlistItems.isEmpty) {
      final loc = context.loc;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            loc.t('watchlist_mass_alerts_empty'),
          ),
        ),
      );
      return;
    }

    try {
      // Use mass alert settings (independent from view settings)
      final indicatorName = _massAlertIndicator.toJson();

      Map<String, dynamic>? indicatorParams;
      if (_massAlertIndicator == IndicatorType.stoch &&
          _massAlertStochDPeriod != null) {
        indicatorParams = {'dPeriod': _massAlertStochDPeriod};
      }

      // Only include enabled levels
      final levels = <double>[];
      if (_massAlertLowerLevelEnabled) {
        levels.add(_massAlertLowerLevel);
      }
      if (_massAlertUpperLevelEnabled) {
        levels.add(_massAlertUpperLevel);
      }
      
      // Validate: at least one level must be enabled
      if (levels.isEmpty) {
        if (mounted) {
          final loc = context.loc;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(loc.t('create_alert_at_least_one_level_required')),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 3),
            ),
          );
        }
        return;
      }
      
      final createdAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;

      // Show loading indicator
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 16),
                Text(
                    'Creating alerts for ${_watchlistItems.length} instrument(s)...'),
              ],
            ),
            duration: const Duration(seconds: 30),
          ),
        );
      }

      // Get existing watchlist alerts for THIS INDICATOR to avoid duplicates
      // Filter in memory since Isar doesn't support description filtering directly
      final allAlerts = await widget.isar.alertRules.where().findAll();
      final indicatorType = _massAlertIndicator;
      final watchlistAlertDescription = 'WATCHLIST: Mass alert for ${indicatorName}';
      
      // For WPR, also check for 'williams' (server format) in addition to 'wpr' (local format)
      // Use fromJson to normalize indicator values when comparing
      final existingWatchlistAlerts = allAlerts
          .where((a) {
            if (a.description == null) return false;
            // Check if description matches
            if (a.description != watchlistAlertDescription) {
              // Also check alternative description format for WPR (if server returned 'williams')
              if (indicatorType == IndicatorType.williams) {
                final altDescription = 'WATCHLIST: Mass alert for williams';
                if (a.description != altDescription) return false;
              } else {
                return false;
              }
            }
            // Check if indicator matches (normalize using fromJson to handle both 'wpr' and 'williams')
            try {
              final alertIndicatorType = IndicatorType.fromJson(a.indicator);
              return alertIndicatorType == indicatorType;
            } catch (e) {
              return false;
            }
          })
          .toList();
      // Create a set of symbols that already have watchlist alerts for this indicator
      final existingWatchlistSymbols =
          existingWatchlistAlerts.map((a) => a.symbol).toSet();

      // Check for existing custom alerts with same parameters to avoid duplicates
      // Exclude watchlist alerts (both old format and new format)
      final existingCustomAlerts = allAlerts
          .where((a) =>
              (a.description == null ||
              (!a.description!.toUpperCase().contains('WATCHLIST:'))))
          .toList();

      // Create a set of symbols that already have custom alerts with same parameters
      final symbolsWithMatchingCustomAlerts = <String>{};
      for (final customAlert in existingCustomAlerts) {
        // Check if custom alert matches Watchlist Alert parameters
        if (customAlert.symbol.isNotEmpty &&
            customAlert.timeframe == _massAlertTimeframe &&
            customAlert.indicator == indicatorName &&
            customAlert.period == _massAlertPeriod &&
            _areLevelsEqual(customAlert.levels, levels) &&
            _areIndicatorParamsEqual(
                customAlert.indicatorParams, indicatorParams)) {
          symbolsWithMatchingCustomAlerts.add(customAlert.symbol);
        }
      }

      // Collect created alerts for syncing after transaction
      final createdAlerts = <AlertRule>[];
      final skippedSymbols = <String>[];

      // First, get current indicator values for all symbols (outside transaction)
      final symbolValues = <String, Map<String, dynamic>>{};
      for (final item in _watchlistItems) {
        // Skip if watchlist alert already exists for this symbol
        if (existingWatchlistSymbols.contains(item.symbol)) {
          continue;
        }

        // Skip if custom alert with same parameters already exists
        if (symbolsWithMatchingCustomAlerts.contains(item.symbol)) {
          skippedSymbols.add(item.symbol);
          continue;
        }

        try {
          final candles = await _yahooService.fetchCandles(
            item.symbol,
            _massAlertTimeframe,
            limit: _candlesLimitForTimeframe(_massAlertTimeframe),
          );

          if (candles.isNotEmpty) {
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

            final indicatorResults = IndicatorService.calculateIndicatorHistory(
              candlesList,
              _massAlertIndicator,
              _massAlertPeriod,
              indicatorParams,
            );

            if (indicatorResults.isNotEmpty) {
              final currentIndicatorValue = indicatorResults.last.value;
              String? lastSide;
              // Determine initial side based on current value and levels
              if (levels.length == 1) {
                // Only one level enabled
                if (currentIndicatorValue < levels[0]) {
                  lastSide = 'below';
                } else {
                  lastSide = 'above';
                }
              } else {
                // Two levels enabled
                if (currentIndicatorValue < levels[0]) {
                  lastSide = 'below';
                } else if (currentIndicatorValue > levels[1]) {
                  lastSide = 'above';
                } else {
                  lastSide = 'between';
                }
              }

              symbolValues[item.symbol] = {
                'value': currentIndicatorValue,
                'side': lastSide,
                'barTs': candles.last.timestamp,
              };
            }
          }
        } catch (e) {
          debugPrint(
              'Error getting current indicator value for ${item.symbol}: $e');
          // Continue without initializing state - will be initialized on first check
        }
      }

      // Create alerts in transaction (without syncing)
      await widget.isar.writeTxn(() async {
        for (final item in _watchlistItems) {
          // Skip if watchlist alert already exists for this symbol
          if (existingWatchlistSymbols.contains(item.symbol)) {
            continue;
          }

          final alert = AlertRule()
            ..symbol = item.symbol
            ..timeframe = _massAlertTimeframe
            ..indicator = indicatorName
            ..period = _massAlertPeriod
            ..indicatorParams = indicatorParams
            ..levels = List.from(levels)
            ..mode = 'cross' // Always use cross mode with one-way crossing
            ..cooldownSec = _massAlertCooldownSec
            ..active = true
            ..repeatable = _massAlertRepeatable
            ..soundEnabled = true
            ..description = 'WATCHLIST: Mass alert for ${indicatorName}'
            ..createdAt = createdAt;

          await widget.isar.alertRules.put(alert);
          createdAlerts.add(alert);

          // Initialize alert state with current indicator value to prevent immediate notifications
          // Set lastFireTs to current time to activate cooldown and prevent spam notifications
          final symbolData = symbolValues[item.symbol];
          if (symbolData != null) {
            final alertState = AlertState()
              ..ruleId = alert.id
              ..lastIndicatorValue = symbolData['value'] as double
              ..lastSide = symbolData['side'] as String?
              ..lastBarTs = symbolData['barTs'] as int
              ..lastFireTs = DateTime.now().millisecondsSinceEpoch ~/ 1000; // Set to activate cooldown
            await widget.isar.alertStates.put(alertState);
          }
        }
      });

      // Sync all created alerts in parallel (outside transaction)
      if (createdAlerts.isNotEmpty) {
        unawaited(Future.wait(
          createdAlerts.map((alert) => AlertSyncService.syncAlert(
            widget.isar, 
            alert,
            lowerLevelEnabled: _massAlertLowerLevelEnabled,
            upperLevelEnabled: _massAlertUpperLevelEnabled,
            lowerLevelValue: _massAlertLowerLevel,
            upperLevelValue: _massAlertUpperLevel,
          )),
        ));
      }

      // Update UI and show success message
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        String message =
            'Watchlist Alert: ${createdAlerts.length} alert(s) created';
        if (skippedSymbols.isNotEmpty) {
          message +=
              '\n${skippedSymbols.length} symbol(s) skipped (custom alerts exist with same parameters)';
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            backgroundColor:
                skippedSymbols.isNotEmpty ? Colors.orange : Colors.green,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    } catch (e) {
      debugPrint('Error creating mass alerts: $e');
      final loc = context.loc;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              loc.t('watchlist_mass_alerts_error'),
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  int _candlesLimitForTimeframe(String timeframe) {
    switch (timeframe) {
      case '4h':
        return 500;
      case '1d':
        return 730;
      default:
        return 100;
    }
  }

  /// Check if two level lists are equal
  bool _areLevelsEqual(List<double> levels1, List<double> levels2) {
    if (levels1.length != levels2.length) return false;
    for (int i = 0; i < levels1.length; i++) {
      if ((levels1[i] - levels2[i]).abs() > 0.001) return false;
    }
    return true;
  }

  /// Check if two indicator params maps are equal
  bool _areIndicatorParamsEqual(
      Map<String, dynamic>? params1, Map<String, dynamic>? params2) {
    if (params1 == null && params2 == null) return true;
    if (params1 == null || params2 == null) return false;
    if (params1.length != params2.length) return false;
    for (final key in params1.keys) {
      if (!params2.containsKey(key)) return false;
      if (params1[key] != params2[key]) return false;
    }
    return true;
  }

  Future<void> _deleteMassAlerts() async {
    try {
      // Filter in memory - delete only alerts for the CURRENT indicator
      final allAlerts = await widget.isar.alertRules.where().findAll();
      final indicatorType = _massAlertIndicator;
      final indicatorName = indicatorType.toJson();
      final watchlistAlertDescription = 'WATCHLIST: Mass alert for ${indicatorName}';
      
      // For WPR, also check for 'williams' (server format) in addition to 'wpr' (local format)
      // Use fromJson to normalize indicator values when comparing
      final alerts = allAlerts
          .where((a) {
            if (a.description == null) return false;
            // Check if description matches
            if (a.description != watchlistAlertDescription) {
              // Also check alternative description format for WPR (if server returned 'williams')
              if (indicatorType == IndicatorType.williams) {
                final altDescription = 'WATCHLIST: Mass alert for williams';
                if (a.description != altDescription) return false;
              } else {
                return false;
              }
            }
            // Check if indicator matches (normalize using fromJson to handle both 'wpr' and 'williams')
            try {
              final alertIndicatorType = IndicatorType.fromJson(a.indicator);
              return alertIndicatorType == indicatorType;
            } catch (e) {
              return false;
            }
          })
          .toList();

      if (alerts.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No Watchlist Alerts to delete'),
            ),
          );
        }
        return;
      }

      debugPrint('_deleteMassAlerts: Found ${alerts.length} alerts to delete');

      // Collect alerts for syncing deletions after transaction
      final alertsToDelete = <AlertRule>[];

      // Delete all alerts in one transaction
      await widget.isar.writeTxn(() async {
        for (final alert in alerts) {
          // Skip if alert doesn't have a valid id
          final alertId = alert.id;
          if (alertId <= 0) {
            continue;
          }

          // Delete alert state first
          try {
            final alertState = await widget.isar.alertStates
                .filter()
                .ruleIdEqualTo(alertId)
                .findFirst();
            if (alertState != null && alertState.id > 0) {
              await widget.isar.alertStates.delete(alertState.id);
            }
          } catch (e) {
            // Ignore errors - state may not exist
          }

          // Delete alert events
          try {
            final events = await widget.isar.alertEvents
                .filter()
                .ruleIdEqualTo(alertId)
                .findAll();
            for (final event in events) {
              if (event.id > 0) {
                await widget.isar.alertEvents.delete(event.id);
              }
            }
          } catch (e) {
            // Ignore errors - events may not exist
          }

          // Delete alert from local database
          await widget.isar.alertRules.delete(alertId);
          alertsToDelete.add(alert);
        }
      });

      debugPrint('_deleteMassAlerts: Deleted ${alertsToDelete.length} alerts from local database');

      // Update UI immediately (don't wait for server sync)
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Watchlist Alert: ${alertsToDelete.length} alert(s) deleted',
            ),
            backgroundColor: Colors.orange,
            duration: const Duration(seconds: 2),
          ),
        );
      }

      // Sync deletions in parallel (non-blocking, after UI update)
      if (alertsToDelete.isNotEmpty) {
        unawaited(Future.wait(
          alertsToDelete.map(
              (alert) => AlertSyncService.deleteAlert(alert, hardDelete: true)),
        ));
      }
    } catch (e) {
      debugPrint('Error deleting mass alerts: $e');
      final loc = context.loc;
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              loc.t('watchlist_mass_alerts_delete_error'),
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _updateMassAlerts() async {
    if (!_massAlertEnabled || _watchlistItems.isEmpty) {
      debugPrint('_updateMassAlerts: Skipped - enabled: $_massAlertEnabled, items: ${_watchlistItems.length}');
      return;
    }

    try {
      // Use mass alert settings (independent from view settings)
      final indicatorName = _massAlertIndicator.toJson();
      debugPrint('_updateMassAlerts: Starting update for indicator=$indicatorName, timeframe=$_massAlertTimeframe');

      Map<String, dynamic>? indicatorParams;
      if (_massAlertIndicator == IndicatorType.stoch &&
          _massAlertStochDPeriod != null) {
        indicatorParams = {'dPeriod': _massAlertStochDPeriod};
      }

      // Only include enabled levels
      final levels = <double>[];
      if (_massAlertLowerLevelEnabled) {
        levels.add(_massAlertLowerLevel);
      }
      if (_massAlertUpperLevelEnabled) {
        levels.add(_massAlertUpperLevel);
      }
      
      final watchlistSymbols =
          _watchlistItems.map((item) => item.symbol).toSet();

      // Get existing watchlist alerts for THIS INDICATOR
      // Filter in memory since Isar doesn't support description filtering directly
      final allAlerts = await widget.isar.alertRules.where().findAll();
      final indicatorType = _massAlertIndicator;
      final watchlistAlertDescription = 'WATCHLIST: Mass alert for ${indicatorName}';
      
      // For WPR, also check for 'williams' (server format) in addition to 'wpr' (local format)
      // Use fromJson to normalize indicator values when comparing
      final existingAlerts = allAlerts
          .where((a) {
            if (a.description == null) return false;
            // Check if description matches
            if (a.description != watchlistAlertDescription) {
              // Also check alternative description format for WPR (if server returned 'williams')
              if (indicatorType == IndicatorType.williams) {
                final altDescription = 'WATCHLIST: Mass alert for williams';
                if (a.description != altDescription) return false;
              } else {
                return false;
              }
            }
            // Check if indicator matches (normalize using fromJson to handle both 'wpr' and 'williams')
            try {
              final alertIndicatorType = IndicatorType.fromJson(a.indicator);
              return alertIndicatorType == indicatorType;
            } catch (e) {
              return false;
            }
          })
          .toList();
      
      debugPrint('_updateMassAlerts: Found ${existingAlerts.length} existing alerts for $indicatorName');

      final alertsToSync = <AlertRule>[];
      await widget.isar.writeTxn(() async {
        // Update existing alerts
        for (final alert in existingAlerts) {
          if (watchlistSymbols.contains(alert.symbol)) {
            // Check if timeframe actually changed - if so, delete alert state
            final timeframeChanged = alert.timeframe != _massAlertTimeframe;
            debugPrint('_updateMassAlerts: Updating alert for ${alert.symbol}, old timeframe=${alert.timeframe}, new timeframe=$_massAlertTimeframe, changed=$timeframeChanged');
            
            alert.timeframe = _massAlertTimeframe;
            alert.indicator = indicatorName;
            alert.period = _massAlertPeriod;
            alert.indicatorParams = indicatorParams;
            alert.levels = List.from(levels);
            alert.mode = 'cross'; // Always use cross mode with one-way crossing
            alert.cooldownSec = _massAlertCooldownSec;
            alert.repeatable = _massAlertRepeatable;

            await widget.isar.alertRules.put(alert);
            alertsToSync.add(alert);
            
            // If timeframe changed, delete alert state to reset it
            if (timeframeChanged) {
              try {
                final alertState = await widget.isar.alertStates
                    .filter()
                    .ruleIdEqualTo(alert.id)
                    .findFirst();
                if (alertState != null && alertState.id > 0) {
                  await widget.isar.alertStates.delete(alertState.id);
                  debugPrint('_updateMassAlerts: Deleted alert state for ${alert.symbol} due to timeframe change');
                }
              } catch (e) {
                // Ignore errors - state may not exist
              }
            }
          } else {
            // Remove alerts for symbols no longer in watchlist
            // Delete alert state
            try {
              final alertState = await widget.isar.alertStates
                  .filter()
                  .ruleIdEqualTo(alert.id)
                  .findFirst();
              if (alertState != null && alertState.id > 0) {
                await widget.isar.alertStates.delete(alertState.id);
              }
            } catch (e) {
              // Ignore errors - state may not exist
            }
            // Delete alert events
            try {
              final events = await widget.isar.alertEvents
                  .filter()
                  .ruleIdEqualTo(alert.id)
                  .findAll();
              for (final event in events) {
                await widget.isar.alertEvents.delete(event.id);
              }
            } catch (e) {
              debugPrint(
                  'Error deleting alert events for alert ${alert.id}: $e');
            }
            // Delete from remote server
            await AlertSyncService.deleteAlert(alert, hardDelete: true);
            // Delete from local database
            await widget.isar.alertRules.delete(alert.id);
          }
        }

        // Create alerts for new symbols (only if they don't already have watchlist alerts)
        final existingWatchlistSymbols =
            existingAlerts.map((a) => a.symbol).toSet();
        final createdAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;

        for (final item in _watchlistItems) {
          // Only create if symbol doesn't already have a watchlist alert
          if (!existingWatchlistSymbols.contains(item.symbol)) {
            final alert = AlertRule()
              ..symbol = item.symbol
              ..timeframe = _massAlertTimeframe
              ..indicator = indicatorName
              ..period = _massAlertPeriod
              ..indicatorParams = indicatorParams
              ..levels = List.from(levels)
              ..mode = 'cross' // Always use cross mode with one-way crossing
              ..cooldownSec = _massAlertCooldownSec
              ..active = true
            ..repeatable = _massAlertRepeatable
            ..soundEnabled = true
            ..description = 'WATCHLIST: Mass alert for ${indicatorName}'
            ..createdAt = createdAt;

            await widget.isar.alertRules.put(alert);
            unawaited(AlertSyncService.syncAlert(
              widget.isar, 
              alert,
              lowerLevelEnabled: _massAlertLowerLevelEnabled,
              upperLevelEnabled: _massAlertUpperLevelEnabled,
              lowerLevelValue: _massAlertLowerLevel,
              upperLevelValue: _massAlertUpperLevel,
            ));
          }
        }
      });
      
      // Sync all updated alerts after transaction completes
      if (alertsToSync.isNotEmpty) {
        debugPrint('_updateMassAlerts: Syncing ${alertsToSync.length} updated alerts');
        for (final alert in alertsToSync) {
          unawaited(AlertSyncService.syncAlert(
            widget.isar, 
            alert,
            lowerLevelEnabled: _massAlertLowerLevelEnabled,
            upperLevelEnabled: _massAlertUpperLevelEnabled,
            lowerLevelValue: _massAlertLowerLevel,
            upperLevelValue: _massAlertUpperLevel,
          ));
        }
      } else {
        debugPrint('_updateMassAlerts: No alerts to sync');
      }
    } catch (e) {
      debugPrint('Error updating mass alerts: $e');
      debugPrint(e.toString());
    }
  }
}

class _SymbolIndicatorData {
  final double currentIndicatorValue;
  final List<double> indicatorValues;
  final List<int> timestamps;
  final List<IndicatorResult> indicatorResults; // Full results for chart
  final double? price; // Last close price

  _SymbolIndicatorData({
    required this.currentIndicatorValue,
    required this.indicatorValues,
    required this.timestamps,
    required this.indicatorResults,
    this.price,
  });
}
