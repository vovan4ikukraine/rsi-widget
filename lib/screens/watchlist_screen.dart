import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:isar/isar.dart';
import '../models.dart';
import '../models/indicator_type.dart';
import '../services/yahoo_proto.dart';
import '../services/indicator_service.dart';
import '../widgets/indicator_chart.dart';
import '../localization/app_localizations.dart';
import '../services/data_sync_service.dart';
import '../services/auth_service.dart';
import '../services/alert_sync_service.dart';
import '../services/error_service.dart';
import '../state/app_state.dart';
import '../widgets/indicator_selector.dart';
import '../widgets/wpr_level_input_formatter.dart';
import '../utils/context_extensions.dart';
import '../utils/snackbar_helper.dart';
import '../utils/indicator_level_validator.dart';
import '../utils/price_formatter.dart';
import '../config/app_config.dart';
import '../constants/app_constants.dart';
import '../di/app_container.dart';
import '../repositories/i_alert_repository.dart';
import '../repositories/i_watchlist_repository.dart';
import '../utils/preferences_storage.dart';
import '../services/widget_service.dart';

class WatchlistScreen extends StatefulWidget {
  final Isar isar;

  const WatchlistScreen({super.key, required this.isar});

  @override
  State<WatchlistScreen> createState() => _WatchlistScreenState();
}

enum _RsiSortOrder { ascending, descending }

class _WatchlistScreenState extends State<WatchlistScreen>
    with WidgetsBindingObserver {
  final YahooProtoSource _yahooService =
      YahooProtoSource(AppConfig.apiBaseUrl);
  late final WidgetService _widgetService;
  late final IAlertRepository _alertRepository;
  late final IWatchlistRepository _watchlistRepository;

  static const String _sortOrderPrefKey = 'watchlist_sort_order';

  List<WatchlistItem> _watchlistItems = [];
  final Map<String, _SymbolIndicatorData> _indicatorDataMap = {};
  bool _isLoading = false;
  bool _isLoadingData = false; // Flag to prevent duplicate data loading calls
  bool _settingsExpanded = false;
  bool _isActionInProgress = false;
  _RsiSortOrder _currentSortOrder = _RsiSortOrder.ascending;
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
  bool _massAlertOnClose = false;
  /// Blocks the Watchlist alert switch until create/delete/save finish (prevents spam toggling).
  bool _isMassAlertOperationInProgress = false;

  // Helper getter for current indicator (from AppState)
  IndicatorType get _massAlertIndicator => _appState?.selectedIndicator ?? IndicatorType.rsi;
  
  // Helper getter for current indicator's enabled state
  bool get _massAlertEnabled => _massAlertEnabledByIndicator[_massAlertIndicator] ?? false;
  
  // Helper setter for current indicator's enabled state
  set _massAlertEnabled(bool value) {
    _massAlertEnabledByIndicator[_massAlertIndicator] = value;
  }

  /// API uses 'wpr' for Williams; app uses 'williams'
  String get _watchlistApiIndicator =>
      _massAlertIndicator == IndicatorType.williams ? 'wpr' : _massAlertIndicator.toJson();

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
  final TextEditingController _massAlertCooldownController =
      TextEditingController();

  // Scroll controller for scrolling to focused fields
  final ScrollController _settingsScrollController = ScrollController();
  final GlobalKey _settingsKey = GlobalKey();
  final GlobalKey<FormState> _massAlertFormKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _alertRepository = sl<IAlertRepository>();
    _watchlistRepository = sl<IWatchlistRepository>();
    _widgetService = WidgetService(yahooService: _yahooService);
    _updateControllerHints();
    _loadSavedState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final previousIndicator = _previousIndicatorType;
    _appState = AppStateScope.of(context);
    final currentIndicator = _appState?.selectedIndicator ?? IndicatorType.rsi;
    
    // Remove old listener before adding new one to prevent duplicate listeners
    // This prevents _onIndicatorChanged from being called multiple times
    final oldAppState = _appState;
    if (oldAppState != null) {
      oldAppState.removeListener(_onIndicatorChanged);
    }
    
    // Update previousIndicatorType if it's the first time or if it changed
    if (_previousIndicatorType == null || _previousIndicatorType != currentIndicator) {
      _previousIndicatorType = currentIndicator;
      
      // If indicator changed and we already have initial state loaded, trigger reload
      if (previousIndicator != null && previousIndicator != currentIndicator) {
        // Indicator changed - let _onIndicatorChanged handle it via listener
      }
    }
    
    // Add listener only once per didChangeDependencies call
    _appState?.addListener(_onIndicatorChanged);
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
          'watchlist_${_previousIndicatorType!.toJson()}_period',
          periodFromController ?? _indicatorPeriod,
        );
        await prefs.setDouble(
          'watchlist_${_previousIndicatorType!.toJson()}_lower_level',
          lowerFromController ?? _lowerLevel,
        );
        await prefs.setDouble(
          'watchlist_${_previousIndicatorType!.toJson()}_upper_level',
          upperFromController ?? _upperLevel,
        );
        if (_previousIndicatorType == IndicatorType.stoch) {
          final stochDFromController = int.tryParse(_stochDPeriodController.text);
          await prefs.setInt('watchlist_stoch_d_period', stochDFromController ?? _stochDPeriod ?? 3);
        }
        
        // Get current mass alert values from controllers
        final massAlertPeriodFromController = int.tryParse(_massAlertPeriodController.text);
        final massAlertLowerFromController = int.tryParse(_massAlertLowerLevelController.text)?.toDouble();
        final massAlertUpperFromController = int.tryParse(_massAlertUpperLevelController.text)?.toDouble();
        
        // Save mass alert settings for the previous indicator
        final previousIndicatorKey = _previousIndicatorType!.toJson();
        await prefs.setInt('watchlist_mass_alert_${previousIndicatorKey}_period', massAlertPeriodFromController ?? _massAlertPeriod);
        await prefs.setDouble('watchlist_mass_alert_${previousIndicatorKey}_lower_level', massAlertLowerFromController ?? _massAlertLowerLevel);
        await prefs.setDouble('watchlist_mass_alert_${previousIndicatorKey}_upper_level', massAlertUpperFromController ?? _massAlertUpperLevel);
        await prefs.setBool('watchlist_mass_alert_${previousIndicatorKey}_lower_level_enabled', _massAlertLowerLevelEnabled);
        await prefs.setBool('watchlist_mass_alert_${previousIndicatorKey}_upper_level_enabled', _massAlertUpperLevelEnabled);
        
        if (_previousIndicatorType == IndicatorType.stoch) {
          final massAlertStochDFromController = int.tryParse(_massAlertStochDPeriodController.text);
          if (massAlertStochDFromController != null || _massAlertStochDPeriod != null) {
            await prefs.setInt('watchlist_mass_alert_stoch_d_period', massAlertStochDFromController ?? _massAlertStochDPeriod ?? 3);
          }
        }
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

          // Update controllers - for WPR levels, ensure minus sign is preserved
          _indicatorPeriodController.text = _indicatorPeriod.toString();
          final lowerText = _lowerLevel.toStringAsFixed(0);
          final upperText = _upperLevel.toStringAsFixed(0);
          _lowerLevelController.text = lowerText;
          _upperLevelController.text = upperText;
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
          // For WPR levels, ensure minus sign is preserved in controllers
          final massAlertLowerText = _massAlertLowerLevel.toStringAsFixed(0);
          final massAlertUpperText = _massAlertUpperLevel.toStringAsFixed(0);
          _massAlertLowerLevelController.text = massAlertLowerText;
          _massAlertUpperLevelController.text = massAlertUpperText;
          _massAlertCooldownController.text = (_massAlertCooldownSec ~/ 60).toString();
        });
      }

      // Update previous indicator type AFTER loading new settings
      _previousIndicatorType = indicatorType;

      // Save loaded settings so widget can use them
      await _saveState();

      // Clear data and reload when indicator changes
      if (mounted) {
        setState(() {
          _indicatorDataMap.clear();
        });
      }
      _loadAllIndicatorData();
    }
  }

  // Widget updates are handled in settings screen only, not from watchlist
  // ignore: unused_element
  @pragma('vm:entry-point')
  Future<void> _updateWidgetOrder(bool sortDescending) async {
    // No-op: widget updates should only come from settings screen
    // Parameter kept for compatibility with existing callers
    // ignore: avoid_unused_constructor_parameters
    sortDescending; // Suppress unused parameter warning
  }

  String _sortOrderToString(_RsiSortOrder order) {
    switch (order) {
      case _RsiSortOrder.ascending:
        return 'ascending';
      case _RsiSortOrder.descending:
        return 'descending';
    }
  }

  _RsiSortOrder _sortOrderFromString(String? value) {
    switch (value) {
      case 'descending':
        return _RsiSortOrder.descending;
      case 'ascending':
      default:
        return _RsiSortOrder.ascending; // Default: smaller to larger
    }
  }

  Future<void> _saveSortOrderPreference(_RsiSortOrder order) async {
    try {
      final prefs = await PreferencesStorage.instance;
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
    final prefs = await PreferencesStorage.instance;

    // Load watchlist settings (widget settings are independent and NOT used here)
    final watchlistTimeframe = prefs.getString('watchlist_timeframe');
    final indicatorType = _appState?.selectedIndicator ?? IndicatorType.rsi;
    final watchlistPeriod = prefs.getInt('watchlist_${indicatorType.toJson()}_period');

    if (mounted) {
      setState(() {
        // Use watchlist settings, or defaults if not set
        _timeframe = watchlistTimeframe ?? '15m';
        _indicatorPeriod = watchlistPeriod ?? indicatorType.defaultPeriod;
        
        // Load levels with validation to ensure they match the current indicator type
        final savedLowerLevel = prefs.getDouble('watchlist_${indicatorType.toJson()}_lower_level');
        final savedUpperLevel = prefs.getDouble('watchlist_${indicatorType.toJson()}_upper_level');
        
        // Validate saved levels match the current indicator type
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
          _currentSortOrder = _RsiSortOrder.ascending; // Default: smaller to larger
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
            prefs.getInt('watchlist_mass_alert_cooldown_sec') ??
                AppConstants.defaultCooldownSec;
        _massAlertRepeatable =
            prefs.getBool('watchlist_mass_alert_repeatable') ?? true;
        _massAlertOnClose =
            prefs.getBool('watchlist_mass_alert_on_close') ?? false;
        
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

        // Initialize controllers - for WPR levels, ensure minus sign is preserved
        _indicatorPeriodController.text = _indicatorPeriod.toString();
        final lowerText = _lowerLevel.toStringAsFixed(0);
        final upperText = _upperLevel.toStringAsFixed(0);
        _lowerLevelController.text = lowerText;
        _upperLevelController.text = upperText;
        if (_stochDPeriod != null) {
          _stochDPeriodController.text = _stochDPeriod.toString();
        } else {
          _stochDPeriodController.clear();
        }

        // Initialize mass alert controllers
        _massAlertPeriodController.text = _massAlertPeriod.toString();
        if (_massAlertStochDPeriod != null) {
          _massAlertStochDPeriodController.text =
              _massAlertStochDPeriod.toString();
        } else {
          _massAlertStochDPeriodController.clear();
        }
        final massAlertLowerText = _massAlertLowerLevel.toStringAsFixed(0);
        final massAlertUpperText = _massAlertUpperLevel.toStringAsFixed(0);
        _massAlertLowerLevelController.text = massAlertLowerText;
        _massAlertUpperLevelController.text = massAlertUpperText;
        _massAlertCooldownController.text = (_massAlertCooldownSec ~/ 60).toString();
      });
    }

    // Save watchlist settings (widget settings are independent and managed separately)
    // indicatorType is already defined at line 495, reuse it
    await prefs.setInt(
        'watchlist_${indicatorType.toJson()}_period', _indicatorPeriod);
    await prefs.setString('watchlist_timeframe', _timeframe);

    // Fetch watchlist alert settings from server (if signed in)
    // This ensures settings are synced across devices
    await _fetchWatchlistAlertSettingsFromServer();

    _loadWatchlist();
  }

  /// Fetch watchlist alert settings from server and merge with local settings
  Future<void> _fetchWatchlistAlertSettingsFromServer() async {
    if (!AuthService.isSignedIn) return;

    final serverSettings = await DataSyncService.fetchWatchlistAlertSettings();
    if (serverSettings == null || serverSettings.isEmpty) return;

    final prefs = await PreferencesStorage.instance;

    // Update local settings with server values for each indicator
    for (final indicatorKey in ['rsi', 'stoch', 'wpr']) {
      final indicatorSettings = serverSettings[indicatorKey] as Map<String, dynamic>?;
      if (indicatorSettings == null) continue;

      // Map indicator key to IndicatorType; prefs use 'williams' not 'wpr'
      IndicatorType? indicatorType;
      if (indicatorKey == 'rsi') {
        indicatorType = IndicatorType.rsi;
      } else if (indicatorKey == 'stoch') {
        indicatorType = IndicatorType.stoch;
      } else if (indicatorKey == 'wpr') {
        indicatorType = IndicatorType.williams;
      }
      if (indicatorType == null) continue;
      final prefsKey = indicatorType.toJson(); // rsi, stoch, williams

      // Update enabled state
      final enabled = indicatorSettings['enabled'] as bool? ?? false;
      await prefs.setBool('watchlist_mass_alert_${prefsKey}_enabled', enabled);
      _massAlertEnabledByIndicator[indicatorType] = enabled;

      // Update other settings
      final timeframe = indicatorSettings['timeframe'] as String?;
      if (timeframe != null) {
        await prefs.setString('watchlist_mass_alert_timeframe', timeframe);
        if (mounted) {
          setState(() {
            _massAlertTimeframe = timeframe;
          });
        }
      }

      final period = indicatorSettings['period'] as int?;
      if (period != null) {
        await prefs.setInt('watchlist_mass_alert_${prefsKey}_period', period);
        // Update current state if this is the active indicator
        if (indicatorType == (_appState?.selectedIndicator ?? IndicatorType.rsi)) {
          if (mounted) {
            setState(() {
              _massAlertPeriod = period;
              _massAlertPeriodController.text = period.toString();
            });
          }
        }
      }

      final stochDPeriod = indicatorSettings['stochDPeriod'] as int?;
      if (stochDPeriod != null && indicatorKey == 'stoch') {
        await prefs.setInt('watchlist_mass_alert_stoch_d_period', stochDPeriod);
        if (indicatorType == (_appState?.selectedIndicator ?? IndicatorType.rsi)) {
          if (mounted) {
            setState(() {
              _massAlertStochDPeriod = stochDPeriod;
              _massAlertStochDPeriodController.text = stochDPeriod.toString();
            });
          }
        }
      }

      final mode = indicatorSettings['mode'] as String?;
      if (mode != null) {
        await prefs.setString('watchlist_mass_alert_mode', mode);
        if (mounted) {
          setState(() {
            _massAlertMode = mode;
          });
        }
      }

      final lowerLevel = (indicatorSettings['lowerLevel'] as num?)?.toDouble();
      if (lowerLevel != null) {
        await prefs.setDouble('watchlist_mass_alert_${prefsKey}_lower_level', lowerLevel);
        if (indicatorType == (_appState?.selectedIndicator ?? IndicatorType.rsi)) {
          if (mounted) {
            setState(() {
              _massAlertLowerLevel = lowerLevel;
              _massAlertLowerLevelController.text = lowerLevel.toStringAsFixed(0);
            });
          }
        }
      }

      final upperLevel = (indicatorSettings['upperLevel'] as num?)?.toDouble();
      if (upperLevel != null) {
        await prefs.setDouble('watchlist_mass_alert_${prefsKey}_upper_level', upperLevel);
        if (indicatorType == (_appState?.selectedIndicator ?? IndicatorType.rsi)) {
          if (mounted) {
            setState(() {
              _massAlertUpperLevel = upperLevel;
              _massAlertUpperLevelController.text = upperLevel.toStringAsFixed(0);
            });
          }
        }
      }

      final lowerLevelEnabled = indicatorSettings['lowerLevelEnabled'] as bool?;
      if (lowerLevelEnabled != null) {
        await prefs.setBool('watchlist_mass_alert_${prefsKey}_lower_level_enabled', lowerLevelEnabled);
        if (indicatorType == (_appState?.selectedIndicator ?? IndicatorType.rsi)) {
          if (mounted) {
            setState(() {
              _massAlertLowerLevelEnabled = lowerLevelEnabled;
            });
          }
        }
      }

      final upperLevelEnabled = indicatorSettings['upperLevelEnabled'] as bool?;
      if (upperLevelEnabled != null) {
        await prefs.setBool('watchlist_mass_alert_${prefsKey}_upper_level_enabled', upperLevelEnabled);
        if (indicatorType == (_appState?.selectedIndicator ?? IndicatorType.rsi)) {
          if (mounted) {
            setState(() {
              _massAlertUpperLevelEnabled = upperLevelEnabled;
            });
          }
        }
      }

      final cooldownSec = indicatorSettings['cooldownSec'] as int?;
      if (cooldownSec != null) {
        await prefs.setInt('watchlist_mass_alert_cooldown_sec', cooldownSec);
        if (mounted) {
          setState(() {
            _massAlertCooldownSec = cooldownSec;
            _massAlertCooldownController.text = (cooldownSec ~/ 60).toString();
          });
        }
      }

      final repeatable = indicatorSettings['repeatable'] as bool?;
      if (repeatable != null) {
        await prefs.setBool('watchlist_mass_alert_repeatable', repeatable);
        if (mounted) {
          setState(() {
            _massAlertRepeatable = repeatable;
          });
        }
      }

      final onClose = indicatorSettings['onClose'] as bool?;
      if (onClose != null) {
        await prefs.setBool('watchlist_mass_alert_on_close', onClose);
        if (mounted) {
          setState(() {
            _massAlertOnClose = onClose;
          });
        }
      }
    }

    debugPrint('WatchlistScreen: Fetched and applied watchlist alert settings from server');
    // Keep local alerts in sync with server (e.g. after disable on another device)
    unawaited(AlertSyncService.fetchAndSyncAlerts());
  }

  Future<void> _saveState() async {
    final prefs = await PreferencesStorage.instance;
    await prefs.setString('watchlist_timeframe', _timeframe);
    final indicatorType = _appState?.selectedIndicator ?? IndicatorType.rsi;
    await prefs.setInt(
        'watchlist_${indicatorType.toJson()}_period', _indicatorPeriod);
    await prefs.setDouble('watchlist_${indicatorType.toJson()}_lower_level', _lowerLevel);
    await prefs.setDouble('watchlist_${indicatorType.toJson()}_upper_level', _upperLevel);
    if (indicatorType == IndicatorType.stoch && _stochDPeriod != null) {
      await prefs.setInt('watchlist_stoch_d_period', _stochDPeriod!);
    }
    // NOTE: Widget settings are managed separately and should NOT be synced from watchlist
    // Widget indicator/period/timeframe should only be changed from widget settings screen
    // This allows users to have different indicators in watchlist and widget

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
    await prefs.setBool(
        'watchlist_mass_alert_on_close', _massAlertOnClose);

    // Sync watchlist alert settings to server (for cross-device sync)
    // Only sync for the current indicator. API uses 'wpr' for Williams.
    unawaited(DataSyncService.syncWatchlistAlertSettings(
      indicator: _watchlistApiIndicator,
      enabled: _massAlertEnabled,
      timeframe: _massAlertTimeframe,
      period: _massAlertPeriod,
      stochDPeriod: _massAlertStochDPeriod,
      mode: _massAlertMode,
      lowerLevel: _massAlertLowerLevel,
      upperLevel: _massAlertUpperLevel,
      lowerLevelEnabled: _massAlertLowerLevelEnabled,
      upperLevelEnabled: _massAlertUpperLevelEnabled,
      cooldownSec: _massAlertCooldownSec,
      repeatable: _massAlertRepeatable,
      onClose: _massAlertOnClose,
    ));

    // NOTE: Widget is NOT updated here - only in _applySettings() when user explicitly applies changes
    // This prevents widget from changing when indicator is switched in AppState
  }

  // Reload list when app returns from background
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadWatchlist();
      // Check if timeframe changed in widget and update data
      _checkWidgetTimeframe();
      // Re-fetch watchlist alert settings from server (in case they changed on another device)
      unawaited(_fetchWatchlistAlertSettingsFromServer());
    }
  }

  Future<void> _checkWidgetTimeframe() async {
    // Load period from widget (if changed in widget)
    // NOTE: Timeframe should NOT be synced from widget - watchlist has its own timeframe selector
    // Widget timeframe and watchlist timeframe are independent
    final prefs = await PreferencesStorage.instance;
    final widgetPeriod = prefs.getInt('rsi_widget_period');
    final widgetNeedsRefresh = prefs.getBool('widget_needs_refresh') ?? false;

    bool needsUpdate = false;

    // Only sync period from widget, NOT timeframe
    // If period changed in widget, update it in app
    if (widgetPeriod != null) {
      if (mounted) {
        setState(() {
          _indicatorPeriod = widgetPeriod;
        });
      }
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
    _appState?.removeListener(_onIndicatorChanged);
    _settingsScrollController.dispose();
    _indicatorPeriodController.dispose();
    _lowerLevelController.dispose();
    _upperLevelController.dispose();
    _stochDPeriodController.dispose();
    _massAlertPeriodController.dispose();
    _massAlertStochDPeriodController.dispose();
    _massAlertLowerLevelController.dispose();
    _massAlertUpperLevelController.dispose();
    _massAlertCooldownController.dispose();
    // Reset loading flag
    _isLoadingData = false;
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
        await DataSyncService.fetchWatchlist();
      } else {
        // In anonymous mode, restore from cache if database is empty
        final existingItems = await _watchlistRepository.getAll();
        if (existingItems.isEmpty) {
          await DataSyncService.restoreWatchlistFromCache();
        }
      }

      // Load all items from database
      final items = await _watchlistRepository.getAll();
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

      _applySortOrder(
        _currentSortOrder,
        persistPreference: false,
        notifyWidget: false,
      );

      // Load indicator data for all symbols
      await _loadAllIndicatorData();

    } catch (e, stackTrace) {
      debugPrint('WatchlistScreen: Error loading list: $e');
      debugPrint('WatchlistScreen: Stack trace: $stackTrace');
      if (mounted) {
        context.showError(
          context.loc.t('watchlist_error_loading', params: {'message': '$e'}),
        );
      }
    }
  }

  Future<void> _loadAllIndicatorData() async {
    if (_watchlistItems.isEmpty) return;
    
    // Prevent duplicate loading calls for the same indicator
    // But allow loading if indicator changed
    if (_isLoadingData) {
      debugPrint('WatchlistScreen: _loadAllIndicatorData already in progress, skipping duplicate call');
      return;
    }

    _isLoadingData = true;
    if (mounted) {
      setState(() {
        _isLoading = true;
      });
    }

    try {
      // Load data with limited parallelism (max 16 concurrent requests)
      // Load test: 100 concurrent → no 429; cache reduces actual HTTP requests
      const maxConcurrent = 16;
      final symbols = _watchlistItems.map((item) => item.symbol).toList();

      for (int i = 0; i < symbols.length; i += maxConcurrent) {
        final batch = symbols.skip(i).take(maxConcurrent).toList();
        await Future.wait(
          batch.map((symbol) => _loadIndicatorDataForSymbol(symbol)),
          eagerError: false, // Continue even if some fail
        );
      }
    } finally {
      _applySortOrder(
        _currentSortOrder,
        persistPreference: false,
        notifyWidget: false,
      );
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
      _isLoadingData = false;
    }
  }

  Future<void> _loadIndicatorDataForSymbol(String symbol) async {
    const maxRetries = 3;
    int attempt = 0;
    final indicatorType = _appState?.selectedIndicator ?? IndicatorType.rsi;

    while (attempt < maxRetries) {
      try {
        // Use same candle limit calculation as CRON (ensures consistency)
        final limit = _candlesLimitForTimeframe(_timeframe, _indicatorPeriod);

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
    await _watchlistRepository.delete(item.id);
    if (mounted) {
      setState(() {
        _watchlistItems.remove(item);
        _indicatorDataMap.remove(item.symbol);
      });
    }
    // Sync watchlist: to server if authenticated, to cache if anonymous
    if (AuthService.isSignedIn) {
      unawaited(DataSyncService.syncWatchlist());
    } else {
      unawaited(DataSyncService.saveWatchlistToCache());
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
      final period = int.tryParse(_indicatorPeriodController.text);
      final lower = int.tryParse(_lowerLevelController.text)?.toDouble();
      final upper = int.tryParse(_upperLevelController.text)?.toDouble();
      final indicatorType = _appState?.selectedIndicator ?? IndicatorType.rsi;
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
        _saveState();
        
        // Update widget with view settings from watchlist (period only, NOT timeframe)
        // Widget uses its own timeframe selector - don't change it from watchlist
        // Indicator type in widget is managed separately (only from widget settings)
        try {
          final indicatorParams = indicatorType == IndicatorType.stoch && _stochDPeriod != null
              ? {'dPeriod': _stochDPeriod}
              : null;
          await _widgetService.updateWidget(
            timeframe: null, // Don't change widget timeframe - widget has its own selector
            rsiPeriod: _indicatorPeriod,
            indicator: indicatorType,
            indicatorParams: indicatorParams,
          );
        } catch (e) {
          // Ignore errors - widget update is non-critical
          debugPrint('Error updating widget from watchlist: $e');
        }
      }

      // Update controllers with current values after applying settings
      // This ensures fields show the actual applied values, not empty
      if (mounted) {
        setState(() {
          // Always update controllers with current state values
          // This makes sure fields are not empty after applying
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
            // Clear stochDPeriod controller if not using Stochastic
            _stochDPeriodController.clear();
          }
        });
      }

      // Don't call _updateControllerHints() here - it clears the controllers
      // We want to keep the values visible after applying

      if (changed) {
        await _loadAllIndicatorData();
      } else {
        if (mounted) {
          setState(() {});
        }
      }

      // Ensure controllers are updated after all operations
      // This is important because _loadAllIndicatorData might trigger rebuilds
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
      setState(() {
        // Don't reset timeframe - keep user's selected timeframe
        // _timeframe = '15m'; // Removed - keep current timeframe
        _indicatorPeriod = indicatorType.defaultPeriod;
        _lowerLevel = indicatorType.defaultLevels.first;
        _upperLevel = indicatorType.defaultLevels.length > 1
            ? indicatorType.defaultLevels[1]
            : 100.0;
        if (indicatorType == IndicatorType.stoch) {
          // Use default dPeriod = 3 (not 6 from defaultParams, as user expects 3)
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
      
      // Update widget with reset settings immediately (same as _applySettings)
      // This ensures widget reflects reset values without needing to press apply button
      try {
        final indicatorParams = indicatorType == IndicatorType.stoch && _stochDPeriod != null
            ? {'dPeriod': _stochDPeriod}
            : null;
        await _widgetService.updateWidget(
          timeframe: null, // Don't change widget timeframe - widget has its own selector
          rsiPeriod: _indicatorPeriod,
          indicator: indicatorType,
          indicatorParams: indicatorParams,
        );
      } catch (e) {
        // Ignore errors - widget update is non-critical
        debugPrint('Error updating widget from reset settings: $e');
      }
      
      _updateControllerHints();
      _loadAllIndicatorData();
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

  // Validate mass alert level based on indicator type
  bool _isValidMassAlertLevel(double value, bool isLower, double? otherLevel) {
    final indicatorType = _massAlertIndicator;
    final valueStr = value.toInt().toString();
    final validationResult = IndicatorLevelValidator.validateLevel(
      valueStr,
      indicatorType,
      true, // Always enabled for mass alerts
      otherLevel: otherLevel,
      isLower: isLower,
    );
    return validationResult == null; // null means valid
  }

  // Scroll to settings when a field is focused and keyboard is open
  void _scrollToSettings() {
    final keyboardHeight = MediaQuery.of(context).viewInsets.bottom;
    if (keyboardHeight > 0 && _settingsScrollController.hasClients) {
      // Wait for the widget to rebuild after keyboard opens
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_settingsScrollController.hasClients && _settingsKey.currentContext != null) {
          final renderBox = _settingsKey.currentContext?.findRenderObject() as RenderBox?;
          if (renderBox != null) {
            final settingsPosition = renderBox.localToGlobal(Offset.zero).dy;
            final currentScrollOffset = _settingsScrollController.offset;
            final targetOffset = currentScrollOffset + settingsPosition - 100; // 100px from top
            
            if (targetOffset >= 0) {
              _settingsScrollController.animateTo(
                targetOffset,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
              );
            }
          }
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(loc.t('watchlist_title')),
            if (_isLoading || _isActionInProgress || _isLoadingData) ...[
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
                  setState(() {
                    _timeframe = value;
                  });
                  _saveState();
                  // Don't update widget timeframe - widget has its own timeframe selector
                  _loadAllIndicatorData(); // Automatically reload data when timeframe changes
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
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final keyboardHeight = MediaQuery.of(context).viewInsets.bottom;
          final hasKeyboard = keyboardHeight > 0;
          
          return SingleChildScrollView(
            controller: _settingsScrollController,
            child: Column(
              children: [
                // Indicator selector (always at top, fixed)
                if (_appState != null) IndicatorSelector(appState: _appState!),
                
                // Collapsible settings bar (fixed)
                Card(
                  key: _settingsKey,
                  margin: const EdgeInsets.only(top: 8),
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
                                      onTap: _scrollToSettings,
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
                                        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9]'))],
                                        onTap: _scrollToSettings,
                                        // Don't save on change - only save when apply button is pressed
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
                                      onTap: _scrollToSettings,
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
                                      onTap: _scrollToSettings,
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
                                _currentSortOrder == _RsiSortOrder.descending
                                    ? Icons.north
                                    : Icons.south,
                                color: _currentSortOrder == _RsiSortOrder.descending
                                    ? Colors.green
                                    : Colors.red,
                              ),
                              tooltip: _currentSortOrder == _RsiSortOrder.descending
                                  ? loc.t('watchlist_sort_desc')
                                  : loc.t('watchlist_sort_asc'),
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
                                        notifyWidget: false,
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

                // Scrollable instruments list
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: hasKeyboard
                        ? MediaQuery.of(context).size.height - keyboardHeight - 200
                        : constraints.maxHeight - 200,
                  ),
                  child: _buildWatchlistList(loc),
                ),
                
                // Add padding at bottom when keyboard is open
                if (hasKeyboard) SizedBox(height: keyboardHeight + 16),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildWatchlistList(AppLocalizations loc) {
    if (_isLoading && _watchlistItems.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_watchlistItems.isEmpty) {
      return Center(
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
      );
    }
    return RefreshIndicator(
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
                padding: const EdgeInsets.only(top: 8, bottom: 16),
                itemCount: _watchlistItems.length + 1, // +1 for counter
                itemBuilder: (context, index) {
                  // First item is the counter
                  if (index == 0) {
                    return Padding(
                      padding: const EdgeInsets.only(left: 16, top: 4, bottom: 8),
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
                    );
                  }
                  
                  // Adjust index for watchlist items
                  final itemIndex = index - 1;
                  if (itemIndex >= _watchlistItems.length) {
                    debugPrint(
                        'WatchlistScreen: ERROR! Index $itemIndex >= list length ${_watchlistItems.length}');
                    return const SizedBox.shrink();
                  }

                  final item = _watchlistItems[itemIndex];
                  debugPrint(
                      'WatchlistScreen: Displaying item $itemIndex: ${item.symbol} (id: ${item.id})');

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
                          PriceFormatter.formatPrice(indicatorData.price!),
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
      margin: const EdgeInsets.only(top: 8, bottom: 8),
      child: ExpansionTile(
        title: Row(
          children: [
            const Icon(Icons.notifications_active, size: 20),
            const SizedBox(width: 8),
            Text(
              loc.t('watchlist_mass_alerts_title'),
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
          onChanged: _isMassAlertOperationInProgress
              ? null
              : (value) async {
                  if (_isMassAlertOperationInProgress) return;
                  // If trying to enable, validate form first
                  if (value && _massAlertFormKey.currentState != null) {
                    if (!_massAlertFormKey.currentState!.validate()) {
                      return;
                    }
                  }
                  // Set flag immediately (before setState) so rapid taps are ignored
                  _isMassAlertOperationInProgress = true;
                  setState(() {
                    _massAlertEnabled = value; // Uses the setter which updates the map
                  });
                  try {
                    await _saveState();
                    if (AuthService.isSignedIn) {
                      await _toggleWatchlistAlertViaServer(value);
                    } else {
                      if (value) {
                        await _createMassAlerts();
                      } else {
                        await _deleteMassAlerts();
                      }
                    }
                  } finally {
                    if (mounted) {
                      setState(() {
                        _isMassAlertOperationInProgress = false;
                      });
                    }
                  }
                },
        ),
        children: [
          // Warning for anonymous users
          if (!AuthService.isSignedIn)
            Container(
              margin: const EdgeInsets.all(12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange.withOpacity(0.1),
                border: Border.all(color: Colors.orange.withOpacity(0.3)),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: Colors.orange[700], size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      loc.t('watchlist_alert_anonymous_warning'),
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.orange[900],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Form(
            key: _massAlertFormKey,
            child: Padding(
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
                      initialValue: _massAlertTimeframe,
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
                // Period and Cooldown in one row
                IntrinsicHeight(
                  child: Row(
                    children: [
                      // Period
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
                              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9]'))],
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
                                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9]'))],
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
                      const SizedBox(width: 8),
                      // Cooldown
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              loc.t('create_alert_cooldown_label'),
                              style: const TextStyle(fontSize: 12, color: Colors.grey),
                            ),
                            const Spacer(),
                            TextField(
                              controller: _massAlertCooldownController,
                              decoration: const InputDecoration(
                                border: OutlineInputBorder(),
                                isDense: true,
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                              ),
                              keyboardType: TextInputType.number,
                              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9]'))],
                              onChanged: (value) {
                                final minutes = int.tryParse(value);
                                if (minutes != null &&
                                    minutes >= 0 &&
                                    minutes <= 1440) {
                                  final cooldownSec = minutes * 60;
                                  if (cooldownSec != _massAlertCooldownSec) {
                                    setState(() {
                                      _massAlertCooldownSec = cooldownSec;
                                    });
                                    _saveState();
                                    if (_massAlertEnabled) {
                                      unawaited(_updateMassAlerts());
                                    }
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
                          TextFormField(
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
                            keyboardType: TextInputType.numberWithOptions(signed: _massAlertIndicator == IndicatorType.williams),
                            inputFormatters: _massAlertIndicator == IndicatorType.williams
                                ? [WprLevelInputFormatter()]
                                : [FilteringTextInputFormatter.allow(RegExp(r'[0-9]'))],
                            validator: (value) {
                              if (!_massAlertLowerLevelEnabled) return null;
                              if (value == null || value.isEmpty) {
                                return ' '; // Empty string to show red border only
                              }
                              final lower = int.tryParse(value)?.toDouble();
                              if (lower == null) {
                                return ' '; // Empty string to show red border only
                              }
                              final indicatorType = _massAlertIndicator;
                              final isWilliams = indicatorType == IndicatorType.williams;
                              final minRange = isWilliams ? -99.0 : 1.0;
                              final maxRange = isWilliams ? -1.0 : 99.0;
                              if (lower < minRange || lower > maxRange) {
                                return ' '; // Empty string to show red border only
                              }
                              // Check relation to upper level if both enabled
                              if (_massAlertUpperLevelEnabled && _massAlertUpperLevelController.text.isNotEmpty) {
                                final upper = int.tryParse(_massAlertUpperLevelController.text)?.toDouble();
                                if (upper != null && lower >= upper) {
                                  return ' '; // Empty string to show red border only
                                }
                              }
                              return null;
                            },
                            onChanged: (value) {
                              if (value.isEmpty) return;
                              final lower = int.tryParse(value)?.toDouble();
                              if (lower != null && lower != _massAlertLowerLevel) {
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
                          TextFormField(
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
                            keyboardType: TextInputType.numberWithOptions(signed: _massAlertIndicator == IndicatorType.williams),
                            inputFormatters: _massAlertIndicator == IndicatorType.williams
                                ? [WprLevelInputFormatter()]
                                : [FilteringTextInputFormatter.allow(RegExp(r'[0-9]'))],
                            validator: (value) {
                              if (!_massAlertUpperLevelEnabled) return null;
                              if (value == null || value.isEmpty) {
                                return ' '; // Empty string to show red border only
                              }
                              final upper = int.tryParse(value)?.toDouble();
                              if (upper == null) {
                                return ' '; // Empty string to show red border only
                              }
                              final indicatorType = _massAlertIndicator;
                              final isWilliams = indicatorType == IndicatorType.williams;
                              final minRange = isWilliams ? -99.0 : 1.0;
                              final maxRange = isWilliams ? -1.0 : 99.0;
                              if (upper < minRange || upper > maxRange) {
                                return ' '; // Empty string to show red border only
                              }
                              // Check relation to lower level if both enabled
                              if (_massAlertLowerLevelEnabled && _massAlertLowerLevelController.text.isNotEmpty) {
                                final lower = int.tryParse(_massAlertLowerLevelController.text)?.toDouble();
                                if (lower != null && upper <= lower) {
                                  return ' '; // Empty string to show red border only
                                }
                              }
                              return null;
                            },
                            onChanged: (value) {
                              if (value.isEmpty) return;
                              final upper = int.tryParse(value)?.toDouble();
                              if (upper != null && upper != _massAlertUpperLevel) {
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
                const SizedBox(height: 8),
                SwitchListTile(
                  title: Text(loc.t('create_alert_on_close')),
                  subtitle: Text(loc.t('create_alert_on_close_sub')),
                  value: _massAlertOnClose,
                  onChanged: (value) async {
                    setState(() {
                      _massAlertOnClose = value;
                    });
                    await _saveState();
                    if (_massAlertEnabled) {
                      unawaited(_updateMassAlerts());
                    }
                  },
                ),
            ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Validates mass alert level settings. Shows error and returns false if invalid.
  bool _validateMassAlertSettingsForCreate() {
    if (_massAlertLowerLevelEnabled &&
        !_isValidMassAlertLevel(_massAlertLowerLevel, true,
            _massAlertUpperLevelEnabled ? _massAlertUpperLevel : null)) {
      if (mounted) context.showError(context.loc.t('create_alert_invalid_lower_level'));
      return false;
    }
    if (_massAlertUpperLevelEnabled &&
        !_isValidMassAlertLevel(_massAlertUpperLevel, false,
            _massAlertLowerLevelEnabled ? _massAlertLowerLevel : null)) {
      if (mounted) context.showError(context.loc.t('create_alert_invalid_upper_level'));
      return false;
    }
    if (_massAlertLowerLevelEnabled && _massAlertUpperLevelEnabled &&
        _massAlertLowerLevel >= _massAlertUpperLevel) {
      if (mounted) context.showError(context.loc.t('create_alert_invalid_levels_relationship'));
      return false;
    }
    if (!_massAlertLowerLevelEnabled && !_massAlertUpperLevelEnabled) {
      if (mounted) context.showError(context.loc.t('create_alert_at_least_one_level_required'));
      return false;
    }
    return true;
  }

  /// Builds levels list and indicator params for mass alerts.
  ({List<double> levels, Map<String, dynamic>? indicatorParams}) _buildMassAlertLevelsAndParams() {
    final levels = <double>[];
    if (_massAlertLowerLevelEnabled) levels.add(_massAlertLowerLevel);
    if (_massAlertUpperLevelEnabled) levels.add(_massAlertUpperLevel);
    Map<String, dynamic>? indicatorParams;
    if (_massAlertIndicator == IndicatorType.stoch && _massAlertStochDPeriod != null) {
      indicatorParams = {'dPeriod': _massAlertStochDPeriod};
    }
    return (levels: levels, indicatorParams: indicatorParams);
  }

  /// Apply watchlist alert settings via server (signed-in, enabled). No loading/toast. Used when settings change.
  Future<void> _applyWatchlistAlertViaServer() async {
    if (!_massAlertEnabled || _watchlistItems.isEmpty) return;
    if (!_validateMassAlertSettingsForCreate()) return; // Prevent 400 when levels are invalid (0, 100, etc.)
    final result = await DataSyncService.putWatchlistAlert(
      indicator: _watchlistApiIndicator,
      enabled: true,
      timeframe: _massAlertTimeframe,
      period: _massAlertPeriod,
      stochDPeriod: _massAlertStochDPeriod,
      mode: _massAlertMode,
      lowerLevel: _massAlertLowerLevel,
      upperLevel: _massAlertUpperLevel,
      lowerLevelEnabled: _massAlertLowerLevelEnabled,
      upperLevelEnabled: _massAlertUpperLevelEnabled,
      cooldownSec: _massAlertCooldownSec,
      repeatable: _massAlertRepeatable,
      onClose: _massAlertOnClose,
    );
    if (result.ok) await AlertSyncService.fetchAndSyncAlerts();
  }

  /// Server-authoritative toggle (signed-in only). PUT /user/watchlist-alert then fetchAndSyncAlerts.
  Future<void> _toggleWatchlistAlertViaServer(bool enable) async {
    if (enable && _watchlistItems.isEmpty) {
      setState(() => _massAlertEnabled = false);
      context.showInfo(context.loc.t('watchlist_mass_alerts_empty'));
      return;
    }
    if (enable && !_validateMassAlertSettingsForCreate()) {
      setState(() => _massAlertEnabled = false);
      return;
    }
    if (mounted && enable) {
      context.showLoading(
        context.loc.t('watchlist_creating_alerts', params: {'count': '${_watchlistItems.length}'}),
      );
    }
    final result = await DataSyncService.putWatchlistAlert(
      indicator: _watchlistApiIndicator,
      enabled: enable,
      timeframe: _massAlertTimeframe,
      period: _massAlertPeriod,
      stochDPeriod: _massAlertStochDPeriod,
      mode: _massAlertMode,
      lowerLevel: _massAlertLowerLevel,
      upperLevel: _massAlertUpperLevel,
      lowerLevelEnabled: _massAlertLowerLevelEnabled,
      upperLevelEnabled: _massAlertUpperLevelEnabled,
      cooldownSec: _massAlertCooldownSec,
      repeatable: _massAlertRepeatable,
      onClose: _massAlertOnClose,
    );
    if (!result.ok) {
      if (mounted) {
        setState(() => _massAlertEnabled = !enable);
        context.hideSnackBar();
        context.showError(context.loc.t('watchlist_mass_alerts_error'));
      }
      return;
    }
    await AlertSyncService.fetchAndSyncAlerts();
    if (mounted) {
      context.hideSnackBar();
      final loc = context.loc;
      if (enable) {
        context.showSuccess('${loc.t('watchlist_title')} ${loc.t('create_alert_created')}: ${result.createdCount}');
      } else {
        SnackBarHelper.showInfo(
          context,
          '${loc.t('watchlist_title')} ${loc.t('create_alert_deleted')}: ${result.deletedCount}',
        );
      }
    }
  }

  Future<void> _createMassAlerts() async {
    if (_watchlistItems.isEmpty) {
      context.showInfo(context.loc.t('watchlist_mass_alerts_empty'));
      return;
    }
    if (!_validateMassAlertSettingsForCreate()) return;

    try {
      final indicatorName = _massAlertIndicator.toJson();
      final (:levels, :indicatorParams) = _buildMassAlertLevelsAndParams();
      final createdAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;

      // Show loading indicator
      if (mounted) {
        context.showLoading(
          context.loc.t('watchlist_creating_alerts', params: {'count': '${_watchlistItems.length}'}),
        );
      }

      // Get existing watchlist alerts for THIS INDICATOR to avoid duplicates
      final existingWatchlistAlerts = await _alertRepository
          .getWatchlistMassAlertsForIndicator(_massAlertIndicator);
      final existingWatchlistSymbols =
          existingWatchlistAlerts.map((a) => a.symbol).toSet();

      // Check for existing custom alerts with same parameters to avoid duplicates
      final existingCustomAlerts =
          await _alertRepository.getCustomAlerts();

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
            limit: _candlesLimitForTimeframe(_massAlertTimeframe, _massAlertPeriod),
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

      // Create alerts first (they need to be saved to get IDs)
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
          ..alertOnClose = _massAlertOnClose
          ..source = 'watchlist' // Mark as watchlist alert for notification differentiation
          ..description =
              '${AppConstants.watchlistAlertPrefix} Mass alert for $indicatorName'
          ..createdAt = createdAt;

        createdAlerts.add(alert);
      }

      // Save all alerts in batch (they will get IDs)
      if (createdAlerts.isNotEmpty) {
        await _alertRepository.saveAlerts(createdAlerts);
        debugPrint('_createMassAlerts: Created ${createdAlerts.length} alerts');

        // Now create alert states with correct ruleId
        final alertStatesToCreate = <AlertState>[];
        for (final alert in createdAlerts) {
          // Initialize alert state with current indicator value to prevent immediate notifications
          // Set lastFireTs to current time to activate cooldown and prevent spam notifications
          final symbolData = symbolValues[alert.symbol];
          if (symbolData != null && alert.id > 0) {
            final alertState = AlertState()
              ..ruleId = alert.id
              ..lastIndicatorValue = symbolData['value'] as double
              ..lastSide = symbolData['side'] as String?
              ..lastBarTs = symbolData['barTs'] as int
              ..lastFireTs = DateTime.now().millisecondsSinceEpoch ~/ 1000; // Set to activate cooldown
            alertStatesToCreate.add(alertState);
          }
        }

        // Save all alert states in batch
        if (alertStatesToCreate.isNotEmpty) {
          await _alertRepository.saveAlertStates(alertStatesToCreate);
        }
      }

      // Sync all created alerts and wait for completion so switch stays disabled
      if (createdAlerts.isNotEmpty) {
        await Future.wait(
          createdAlerts.map((alert) => AlertSyncService.syncAlert(alert,
            lowerLevelEnabled: _massAlertLowerLevelEnabled,
            upperLevelEnabled: _massAlertUpperLevelEnabled,
            lowerLevelValue: _massAlertLowerLevel,
            upperLevelValue: _massAlertUpperLevel,
          )),
        );
      }

      // Update UI and show success message
      if (mounted) {
        final loc = context.loc;
        context.hideSnackBar();
        String message = '${loc.t('watchlist_title')} ${loc.t('create_alert_created')}: ${createdAlerts.length}';
        if (skippedSymbols.isNotEmpty) {
          message += '\n${skippedSymbols.length} symbol(s) skipped';
        }
        if (skippedSymbols.isNotEmpty) {
          SnackBarHelper.showInfo(context, message);
        } else {
          context.showSuccess(message);
        }
      }
    } catch (e) {
      debugPrint('Error creating mass alerts: $e');
      if (mounted) {
        final loc = context.loc;
        context.showError(loc.t('watchlist_mass_alerts_error'));
      }
    }
  }

  /// Calculate optimal candle limit based on timeframe and period
  /// Ensures we have enough candles for indicator calculation + buffer for charts
  int _candlesLimitForTimeframe(String timeframe, [int? period]) {
    // Minimum candles required for indicators: period + buffer
    final defaultPeriod = AppConstants.defaultIndicatorPeriod;
    final periodBuffer = period != null
        ? period + AppConstants.periodBuffer
        : defaultPeriod + AppConstants.periodBuffer;
    
    // Base minimums per timeframe
    int baseMinimum;
    switch (timeframe) {
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
    return periodBuffer > baseMinimum ? periodBuffer : baseMinimum;
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
      final alerts = await _alertRepository
          .getWatchlistMassAlertsForIndicator(_massAlertIndicator);

      if (alerts.isEmpty) {
        if (mounted) {
          context.showInfo(context.loc.t('watchlist_mass_alerts_empty'));
        }
        return;
      }

      debugPrint('_deleteMassAlerts: Found ${alerts.length} alerts to delete');

      // Collect alerts for syncing deletions after transaction
      final alertsToDelete = <AlertRule>[];
      final alertIdsToDelete = <int>[];

      // Collect valid alert IDs
      for (final alert in alerts) {
        final alertId = alert.id;
        if (alertId > 0) {
          alertIdsToDelete.add(alertId);
          alertsToDelete.add(alert);
        }
      }

      // Delete all alerts with related data in one transaction
      if (alertIdsToDelete.isNotEmpty) {
        await _alertRepository.deleteAlertsWithRelatedData(alertIdsToDelete);
      }

      debugPrint('_deleteMassAlerts: Deleted ${alertsToDelete.length} alerts from local database');

      // Sync deletions and wait so switch stays disabled until server is updated
      if (alertsToDelete.isNotEmpty) {
        await Future.wait(
          alertsToDelete.map(
              (alert) => AlertSyncService.deleteAlert(alert, hardDelete: true)),
        );
      }

      if (mounted) {
        final loc = context.loc;
        SnackBarHelper.showInfo(
          context,
          '${loc.t('watchlist_title')} ${loc.t('create_alert_deleted')}: ${alertsToDelete.length}',
        );
      }
    } catch (e) {
      debugPrint('Error deleting mass alerts: $e');
      if (mounted) {
        final loc = context.loc;
        context.hideSnackBar();
        context.showError(loc.t('watchlist_mass_alerts_delete_error'));
      }
    }
  }

  Future<void> _updateMassAlerts() async {
    if (!_massAlertEnabled || _watchlistItems.isEmpty) {
      debugPrint('_updateMassAlerts: Skipped - enabled: $_massAlertEnabled, items: ${_watchlistItems.length}');
      return;
    }
    if (AuthService.isSignedIn) {
      await _applyWatchlistAlertViaServer();
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

      // Validate levels before updating alerts
      if (_massAlertLowerLevelEnabled && 
          !_isValidMassAlertLevel(_massAlertLowerLevel, true, 
              _massAlertUpperLevelEnabled ? _massAlertUpperLevel : null)) {
        debugPrint('_updateMassAlerts: Invalid lower level $_massAlertLowerLevel');
        return;
      }
      
      if (_massAlertUpperLevelEnabled && 
          !_isValidMassAlertLevel(_massAlertUpperLevel, false, 
              _massAlertLowerLevelEnabled ? _massAlertLowerLevel : null)) {
        debugPrint('_updateMassAlerts: Invalid upper level $_massAlertUpperLevel');
        return;
      }
      
      // Additional validation: check relationship between levels when both are enabled
      if (_massAlertLowerLevelEnabled && _massAlertUpperLevelEnabled) {
        if (_massAlertLowerLevel >= _massAlertUpperLevel) {
          debugPrint('_updateMassAlerts: Invalid levels relationship - lower: $_massAlertLowerLevel, upper: $_massAlertUpperLevel');
          return;
        }
      }

      // Only include enabled and validated levels
      final levels = <double>[];
      if (_massAlertLowerLevelEnabled) {
        levels.add(_massAlertLowerLevel);
      }
      if (_massAlertUpperLevelEnabled) {
        levels.add(_massAlertUpperLevel);
      }
      
      final watchlistSymbols =
          _watchlistItems.map((item) => item.symbol).toSet();

      final existingAlerts = await _alertRepository
          .getWatchlistMassAlertsForIndicator(_massAlertIndicator);
      debugPrint('_updateMassAlerts: Found ${existingAlerts.length} existing alerts for $indicatorName');

      final alertsToSync = <AlertRule>[];
      final alertsToUpdate = <AlertRule>[];
      final alertsToDelete = <AlertRule>[];
      
      // Prepare updates and deletions
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
          alert.alertOnClose = _massAlertOnClose;

          alertsToSync.add(alert);
          alertsToUpdate.add(alert);
            
          // If timeframe changed, delete alert state to reset it
          if (timeframeChanged) {
            await _alertRepository.deleteAlertStateByRuleId(alert.id);
            debugPrint('_updateMassAlerts: Deleted alert state for ${alert.symbol} due to timeframe change');
          }
        } else {
          // Remove alerts for symbols no longer in watchlist
          // Delete from remote server first
          await AlertSyncService.deleteAlert(alert, hardDelete: true);
          // Collect for batch local deletion
          alertsToDelete.add(alert);
        }
      }

      // Batch delete alerts that are no longer in watchlist (with related data)
      if (alertsToDelete.isNotEmpty) {
        final alertIdsToDelete = alertsToDelete
            .where((a) => a.id > 0)
            .map((a) => a.id)
            .toList();
        if (alertIdsToDelete.isNotEmpty) {
          await _alertRepository.deleteAlertsWithRelatedData(alertIdsToDelete);
          debugPrint('_updateMassAlerts: Deleted ${alertIdsToDelete.length} alerts that are no longer in watchlist');
        }
      }

      // Save updated alerts in batch
      if (alertsToUpdate.isNotEmpty) {
        await _alertRepository.saveAlerts(alertsToUpdate);
        debugPrint('_updateMassAlerts: Saved ${alertsToUpdate.length} updated alerts');
      }

      // Create alerts for new symbols (only if they don't already have watchlist alerts)
      final existingWatchlistSymbols =
          existingAlerts.map((a) => a.symbol).toSet();
      final createdAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final createdAlerts = <AlertRule>[];

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
            ..alertOnClose = _massAlertOnClose
            ..source = 'watchlist' // Mark as watchlist alert for notification differentiation
            ..description =
                '${AppConstants.watchlistAlertPrefix} Mass alert for $indicatorName'
            ..createdAt = createdAt;

          createdAlerts.add(alert);
        }
      }

      // Save all new alerts in batch
      if (createdAlerts.isNotEmpty) {
        await _alertRepository.saveAlerts(createdAlerts);
        debugPrint('_updateMassAlerts: Created ${createdAlerts.length} new alerts');

        // Sync new alerts in parallel (outside transaction)
        for (final alert in createdAlerts) {
          unawaited(AlertSyncService.syncAlert(alert,
            lowerLevelEnabled: _massAlertLowerLevelEnabled,
            upperLevelEnabled: _massAlertUpperLevelEnabled,
            lowerLevelValue: _massAlertLowerLevel,
            upperLevelValue: _massAlertUpperLevel,
          ));
        }
      }

      // Sync all updated alerts after transaction completes
      if (alertsToSync.isNotEmpty) {
        debugPrint('_updateMassAlerts: Syncing ${alertsToSync.length} updated alerts');
        for (final alert in alertsToSync) {
          unawaited(AlertSyncService.syncAlert(alert,
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
