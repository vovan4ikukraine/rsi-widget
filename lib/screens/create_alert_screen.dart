import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:isar/isar.dart';
import '../models.dart';
import '../models/indicator_type.dart';
import '../services/yahoo_proto.dart';
import '../services/alert_sync_service.dart';
import '../services/symbol_search_service.dart';
import '../services/error_service.dart';
import '../localization/app_localizations.dart';
import '../state/app_state.dart';
import '../widgets/indicator_selector.dart';
import '../widgets/wpr_level_input_formatter.dart';
import '../utils/context_extensions.dart';
import '../utils/snackbar_helper.dart';
import '../utils/indicator_level_validator.dart';
import '../config/app_config.dart';
import '../constants/app_constants.dart';
import '../di/app_container.dart';
import '../repositories/i_alert_repository.dart';

class CreateAlertScreen extends StatefulWidget {
  final Isar isar;
  final AlertRule? alert;
  final String? initialSymbol;
  final String? initialTimeframe;
  final int? initialPeriod;

  const CreateAlertScreen({
    super.key,
    required this.isar,
    this.alert,
    this.initialSymbol,
    this.initialTimeframe,
    this.initialPeriod,
  });

  @override
  State<CreateAlertScreen> createState() => _CreateAlertScreenState();
}

class _CreateAlertScreenState extends State<CreateAlertScreen> {
  final _formKey = GlobalKey<FormState>();
  final _symbolController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _indicatorPeriodController = TextEditingController();
  final _lowerLevelController = TextEditingController();
  final _upperLevelController = TextEditingController();
  final FocusNode _indicatorPeriodFocusNode = FocusNode();
  final YahooProtoSource _yahooService =
      YahooProtoSource(AppConfig.apiBaseUrl);

  String _selectedTimeframe = '15m';
  int _indicatorPeriod = AppConstants.defaultIndicatorPeriod;
  int? _stochDPeriod; // Stochastic %D period
  List<double> _levels = List.from(AppConstants.defaultLevels);
  bool _lowerLevelEnabled = true;
  bool _upperLevelEnabled = true;
  String _mode = 'cross';
  int _cooldownSec = 600;
  bool _soundEnabled = true;
  bool _alertOnClose = false;
  bool _isLoading = false;
  bool _isSearchingSymbols = false;
  late final SymbolSearchService _symbolSearchService;
  late final IAlertRepository _alertRepository;
  List<SymbolInfo> _popularSymbols = [];
  AppState? _appState;

  @override
  void initState() {
    super.initState();
    _alertRepository = sl<IAlertRepository>();
    _symbolSearchService = SymbolSearchService(_yahooService);
    _loadPopularSymbols();
    if (widget.alert != null) {
      _loadAlertData();
    }
  }

  bool _controllersInitialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _appState = AppStateScope.of(context);
    // If creating new alert, use selected indicator
    if (widget.alert == null && _appState != null && !_controllersInitialized) {
      final indicatorType = _appState!.selectedIndicator;
      
      // Use initial period if provided, otherwise use default
      _indicatorPeriod = widget.initialPeriod ?? indicatorType.defaultPeriod;
      if (_indicatorPeriodController.text.isEmpty) {
        _indicatorPeriodController.text = _indicatorPeriod.toString();
      }
      
      _levels = List.from(indicatorType.defaultLevels);
      _lowerLevelEnabled = _levels.isNotEmpty;
      _upperLevelEnabled = _levels.length > 1;
      if (indicatorType == IndicatorType.stoch) {
        _stochDPeriod = 3;
      }
      // Initialize controllers with default values only if they are empty
      if (_levels.isNotEmpty && _lowerLevelController.text.isEmpty) {
        _lowerLevelController.text = _levels[0].toInt().toString();
      }
      if (_levels.length > 1 && _upperLevelController.text.isEmpty) {
        _upperLevelController.text = _levels[1].toInt().toString();
      }
      
      // Set initial symbol and timeframe if provided
      if (widget.initialSymbol != null && widget.initialSymbol!.isNotEmpty) {
        _symbolController.text = widget.initialSymbol!;
      }
      if (widget.initialTimeframe != null && widget.initialTimeframe!.isNotEmpty) {
        _selectedTimeframe = widget.initialTimeframe!;
      }
      
      _controllersInitialized = true;
    }
  }

  void _loadAlertData() {
    final alert = widget.alert!;
    _symbolController.text = alert.symbol;
    _descriptionController.text = alert.description ?? '';
    _selectedTimeframe = alert.timeframe;
    _indicatorPeriod = alert.period;
    _indicatorPeriodController.text = _indicatorPeriod.toString();
    _levels = List.from(alert.levels);
    _lowerLevelEnabled = _levels.isNotEmpty;
    _upperLevelEnabled = _levels.length > 1;
    _mode = alert.mode;
    _cooldownSec = alert.cooldownSec;
    _soundEnabled = alert.soundEnabled;
    _alertOnClose = alert.alertOnClose;

    // Load indicator-specific parameters
    if (alert.indicatorParams != null) {
      final params = alert.indicatorParams!;
      if (params.containsKey('dPeriod')) {
        _stochDPeriod = params['dPeriod'] as int?;
      }
    }
    
    // Initialize controllers with alert values
    if (_levels.isNotEmpty) {
      _lowerLevelController.text = _levels[0].toInt().toString();
    }
    if (_levels.length > 1) {
      _upperLevelController.text = _levels[1].toInt().toString();
    }
  }

  @override
  void dispose() {
    _symbolController.dispose();
    _descriptionController.dispose();
    _indicatorPeriodController.dispose();
    _lowerLevelController.dispose();
    _upperLevelController.dispose();
    _indicatorPeriodFocusNode.dispose();
    _symbolSearchService.cancelPending();
    super.dispose();
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

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.alert == null
            ? loc.t('create_alert_title_new')
            : loc.t('create_alert_title_edit')),
        titleSpacing: 8, // Reduce spacing between back button and title
        backgroundColor: Colors.blue[900],
        foregroundColor: Colors.white,
        actions: [
          if (widget.alert != null)
            IconButton(
              icon: const Icon(Icons.delete),
              onPressed: _deleteAlert,
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  // Indicator selector
                  if (_appState != null)
                    IndicatorSelector(appState: _appState!),
                  const SizedBox(height: 16),

                  // Basic information
                  _buildBasicInfoCard(loc),
                  const SizedBox(height: 16),

                  // Indicator settings
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: _buildIndicatorSettingsCard(loc),
                  ),
                  const SizedBox(height: 16),

                  // Alert settings
                  _buildAlertSettingsCard(loc),
                  const SizedBox(height: 16),

                  // Buttons
                  _buildActionButtons(loc),
                ],
              ),
            ),
    );
  }

  Widget _buildBasicInfoCard(AppLocalizations loc) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              loc.t('create_alert_basic_title'),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Autocomplete<SymbolInfo>(
              optionsBuilder: (TextEditingValue textEditingValue) async {
                final query = textEditingValue.text.trim();

                if (widget.alert != null &&
                    query == widget.alert!.symbol &&
                    textEditingValue.selection.baseOffset ==
                        textEditingValue.selection.extentOffset) {
                  return const Iterable<SymbolInfo>.empty();
                }

                if (query.isEmpty) {
                  if (_popularSymbols.isEmpty) {
                    try {
                      final popular =
                          await _symbolSearchService.getPopularSymbols();
                      if (mounted) {
                        setState(() {
                          _popularSymbols = popular;
                        });
                      }
                      return popular.take(30);
                    } catch (_) {
                      return const Iterable<SymbolInfo>.empty();
                    }
                  }
                  return _popularSymbols.take(30);
                }

                if (query.length == 1) {
                  final upper = query.toUpperCase();
                  if (_popularSymbols.isEmpty) {
                    try {
                      final popular =
                          await _symbolSearchService.getPopularSymbols();
                      if (mounted) {
                        setState(() {
                          _popularSymbols = popular;
                        });
                      }
                    } catch (_) {
                      return const Iterable<SymbolInfo>.empty();
                    }
                  }
                  return _popularSymbols
                      .where((symbol) => _matchesSymbol(symbol, upper))
                      .take(20);
                }

                if (!_isSearchingSymbols && mounted) {
                  setState(() {
                    _isSearchingSymbols = true;
                  });
                }

                try {
                  final suggestions =
                      await _symbolSearchService.resolveSuggestions(query);
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
                // Initialize controller when editing or when initial symbol is provided
                if ((widget.alert != null || widget.initialSymbol != null) && 
                    _symbolController.text.isNotEmpty) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted && textEditingController.text != _symbolController.text) {
                      textEditingController.text = _symbolController.text;
                    }
                  });
                }

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      loc.t('home_symbol_label'),
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    const SizedBox(height: 4),
                    TextFormField(
                      controller: textEditingController,
                      focusNode: focusNode,
                      decoration: InputDecoration(
                        hintText: loc.t('home_symbol_hint'),
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(Icons.trending_up),
                        suffixIcon: _isSearchingSymbols
                            ? const Padding(
                                padding: EdgeInsets.all(12.0),
                                child: SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                ),
                              )
                            : null,
                      ),
                      onChanged: (value) {
                        if (mounted) {
                          _symbolController.text = value;
                        }
                      },
                      validator: (value) {
                        if (value == null ||
                            value.isEmpty ||
                            value.trim().isEmpty) {
                          return loc.t('create_alert_symbol_error');
                        }
                        return null;
                      },
                    ),
                  ],
                );
              },
              onSelected: (SymbolInfo selection) {
                if (!mounted) return;
                _symbolController.text = selection.symbol;
                FocusScope.of(context).unfocus();
              },
              optionsViewBuilder: (BuildContext context,
                  AutocompleteOnSelected<SymbolInfo> onSelected,
                  Iterable<SymbolInfo> options) {
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
                            loc.t('search_no_results'),
                            style: const TextStyle(color: Colors.grey),
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
                      constraints: const BoxConstraints(maxHeight: 220),
                      child: ListView.builder(
                        padding: EdgeInsets.zero,
                        shrinkWrap: true,
                        itemCount: options.length,
                        itemBuilder: (BuildContext context, int index) {
                          final SymbolInfo option = options.elementAt(index);
                          return InkWell(
                            onTap: () => onSelected(option),
                            child: Padding(
                              padding: const EdgeInsets.all(16.0),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
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
                                                  fontWeight: FontWeight.bold),
                                            ),
                                            if (option.type.isNotEmpty)
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                  horizontal: 8,
                                                  vertical: 4,
                                                ),
                                                decoration: BoxDecoration(
                                                  color: Colors.blueGrey[900],
                                                  borderRadius:
                                                      BorderRadius.circular(12),
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
                                                const EdgeInsets.only(top: 4.0),
                                            child: Text(
                                              option.name,
                                              style: TextStyle(
                                                fontSize: 12,
                                                color: Colors.grey[500],
                                              ),
                                            ),
                                          ),
                                        if (option.shortExchange.isNotEmpty)
                                          Padding(
                                            padding:
                                                const EdgeInsets.only(top: 2.0),
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
            const SizedBox(height: 16),
            Column(
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
                    prefixIcon: Icon(Icons.schedule),
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
                }
              },
            ),
          ],
        ),
        const SizedBox(height: 16),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              loc.t('create_alert_description_label'),
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 4),
            TextFormField(
              controller: _descriptionController,
              decoration: InputDecoration(
                hintText: loc.t('create_alert_description_hint'),
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.description),
              ),
              maxLines: 2,
            ),
          ],
        ),
          ],
        ),
      ),
    );
  }

  Widget _buildIndicatorSettingsCard(AppLocalizations loc) {
    final indicatorType = _appState?.selectedIndicator ?? IndicatorType.rsi;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              loc.t('markets_indicator_settings'),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
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
                              return loc.t('home_period_label');
                          }
                        }(),
                        style: const TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                      const Spacer(),
                      TextFormField(
                        controller: _indicatorPeriodController,
                        focusNode: _indicatorPeriodFocusNode,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.timeline),
                        ),
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9]'))],
                        onChanged: (value) {
                          // Allow typing/erasing without rebuilding the widget (prevents focus jump).
                          if (value.isEmpty) return;
                          final period = int.tryParse(value);
                          if (period != null && period >= 1 && period <= 100) {
                            _indicatorPeriod = period;
                          }
                        },
                      ),
                    ],
                  ),
                ),
                if (indicatorType == IndicatorType.stoch) ...[
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          loc.t('home_stoch_d_period_label'),
                          style: const TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                        const Spacer(),
                        TextFormField(
                          initialValue: (_stochDPeriod ?? 3).toString(),
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            prefixIcon: Icon(Icons.timeline),
                          ),
                          keyboardType: TextInputType.number,
                          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9]'))],
                          onChanged: (value) {
                            final dPeriod = int.tryParse(value);
                            if (dPeriod != null && dPeriod >= 1 && dPeriod <= 100) {
                              setState(() {
                                _stochDPeriod = dPeriod;
                              });
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
            Text(
              loc.t('create_alert_levels_title'),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 8),
            _buildLevelsSelector(indicatorType),
          ],
        ),
      ),
    );
  }

  Widget _buildLevelsSelector(IndicatorType indicatorType) {
    final defaultLevels = indicatorType.defaultLevels;
    
    return Column(
      children: [
        IntrinsicHeight(
          child: Row(
            children: [
              Checkbox(
              value: _lowerLevelEnabled,
              onChanged: (value) {
                if (value == false && !_upperLevelEnabled) {
                  // Prevent disabling both levels
                  return;
                }
                setState(() {
                  _lowerLevelEnabled = value ?? true;
                  if (!_lowerLevelEnabled && _levels.isNotEmpty) {
                    _levels.removeAt(0);
                  } else if (_lowerLevelEnabled && _levels.isEmpty) {
                    // Restore previous value if user already entered it; otherwise use default.
                    final restored = int.tryParse(_lowerLevelController.text)?.toDouble();
                    final valueToUse = restored ?? defaultLevels.first;
                    _levels.insert(0, valueToUse);
                    _lowerLevelController.text = valueToUse.toInt().toString();
                  }
                });
              },
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.loc.t('create_alert_lower_level'),
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const Spacer(),
                  TextFormField(
                    controller: _lowerLevelController,
                    enabled: _lowerLevelEnabled,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.numberWithOptions(signed: indicatorType == IndicatorType.williams),
                    inputFormatters: indicatorType == IndicatorType.williams
                        ? [WprLevelInputFormatter()]
                        : [FilteringTextInputFormatter.allow(RegExp(r'[0-9]'))],
                    validator: (value) {
                      final upperLevel = _upperLevelEnabled && _upperLevelController.text.isNotEmpty
                          ? int.tryParse(_upperLevelController.text)?.toDouble()
                          : null;
                      return IndicatorLevelValidator.validateLevel(
                        value,
                        indicatorType,
                        _lowerLevelEnabled,
                        otherLevel: upperLevel,
                        isLower: true,
                      );
                    },
                    onChanged: (value) {
                      if (value.isEmpty) return;
                      final lower = int.tryParse(value)?.toDouble();
                      if (lower != null) {
                        setState(() {
                          if (_levels.isEmpty) {
                            _levels.add(lower);
                          } else {
                            _levels[0] = lower;
                          }
                        });
                      }
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Checkbox(
              value: _upperLevelEnabled,
              onChanged: (value) {
                if (value == false && !_lowerLevelEnabled) {
                  // Prevent disabling both levels
                  return;
                }
                setState(() {
                  _upperLevelEnabled = value ?? true;
                  if (!_upperLevelEnabled && _levels.length > 1) {
                    _levels.removeAt(1);
                    _upperLevelController.clear();
                  } else if (_upperLevelEnabled && _levels.length < 2) {
                    // Don't add default values - user must enter valid levels
                    // Just initialize the controller if needed
                    if (_upperLevelController.text.isEmpty) {
                      final upperValue = defaultLevels.length > 1
                          ? defaultLevels[1]
                          : AppConstants.maxIndicatorLevel;
                      _upperLevelController.text = upperValue.toInt().toString();
                      _levels.add(upperValue);
                    }
                  }
                });
              },
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.loc.t('create_alert_upper_level'),
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const Spacer(),
                  TextFormField(
                    controller: _upperLevelController,
                    enabled: _upperLevelEnabled,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.numberWithOptions(signed: indicatorType == IndicatorType.williams),
                    inputFormatters: indicatorType == IndicatorType.williams
                        ? [WprLevelInputFormatter()]
                        : [FilteringTextInputFormatter.allow(RegExp(r'[0-9]'))],
                    validator: (value) {
                      final lowerLevel = _lowerLevelEnabled && _lowerLevelController.text.isNotEmpty
                          ? int.tryParse(_lowerLevelController.text)?.toDouble()
                          : null;
                      return IndicatorLevelValidator.validateLevel(
                        value,
                        indicatorType,
                        _upperLevelEnabled,
                        otherLevel: lowerLevel,
                        isLower: false,
                      );
                    },
                    onChanged: (value) {
                      if (value.isEmpty) return;
                      final upper = int.tryParse(value)?.toDouble();
                      if (upper != null) {
                        setState(() {
                          if (_levels.length < 2) {
                            if (_levels.isEmpty) {
                              _levels.add(upper);
                            } else {
                              _levels.add(upper);
                            }
                          } else {
                            _levels[1] = upper;
                          }
                        });
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
    );
  }

  Widget _buildAlertSettingsCard(AppLocalizations loc) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              loc.t('create_alert_settings_title'),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
          Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
              Text(
                loc.t('create_alert_cooldown_label'),
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 4),
              TextFormField(
                initialValue: (_cooldownSec ~/ 60).toString(),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.timer),
                ),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9]'))],
                onChanged: (value) {
                  final minutes = int.tryParse(value);
                  if (minutes != null &&
                      minutes >= 0 &&
                      minutes <= 1440) {
                    _cooldownSec = minutes * 60;
                  }
                },
              ),
            ],
          ),
            const SizedBox(height: 16),
            SwitchListTile(
              title: Text(loc.t('create_alert_sound')),
              subtitle: Text(loc.t('create_alert_sound_sub')),
              value: _soundEnabled,
              onChanged: (value) {
                setState(() {
                  _soundEnabled = value;
                });
              },
            ),
            SwitchListTile(
              title: Text(loc.t('create_alert_on_close')),
              subtitle: Text(loc.t('create_alert_on_close_sub')),
              value: _alertOnClose,
              onChanged: (value) {
                setState(() {
                  _alertOnClose = value;
                });
              },
            ),
          ],
        ),
      ),
    );
  }

  bool _matchesSymbol(SymbolInfo info, String upper) {
    final symbolUpper = info.symbol.toUpperCase();
    final nameUpper = info.name.toUpperCase();
    return symbolUpper.startsWith(upper) || nameUpper.startsWith(upper);
  }

  Widget _buildActionButtons(AppLocalizations loc) {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton(
            onPressed: () => Navigator.pop(context),
            child: Text(loc.t('create_alert_cancel')),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: ElevatedButton(
            onPressed: _saveAlert,
            child: Text(widget.alert == null
                ? loc.t('create_alert_create')
                : loc.t('create_alert_save')),
          ),
        ),
      ],
    );
  }

  Future<void> _saveAlert() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      final loc = context.loc;
      // Symbol validation
      final symbol = _symbolController.text.trim().toUpperCase();
      if (symbol.isEmpty) {
        if (mounted) {
          context.showError(loc.t('create_alert_symbol_error'));
        }
        return;
      }

      // Validate that symbol exists
      try {
        final symbolInfo =
            await _symbolSearchService.resolveSuggestions(symbol);
        final exactMatch =
            symbolInfo.where((s) => s.symbol.toUpperCase() == symbol).toList();
        if (exactMatch.isEmpty) {
          if (mounted) {
            context.showError(
              loc.t('error_symbol_not_found', params: {'symbol': symbol}),
            );
          }
          return;
        }
      } catch (e) {
        // Log error to server
        ErrorService.logError(
          error: e,
          context: 'create_alert_screen_validate_symbol',
          symbol: symbol,
        );
        
        // If validation fails, still allow creation but show warning
        if (mounted) {
          SnackBarHelper.showInfo(
            context,
            loc.t('error_symbol_validation_failed', params: {'symbol': symbol}),
          );
        }
      }

      // Get selected indicator
      final indicatorType = _appState?.selectedIndicator ?? IndicatorType.rsi;
      final indicatorName = indicatorType.toJson();

      // Prepare indicator parameters
      Map<String, dynamic>? indicatorParams;
      if (indicatorType == IndicatorType.stoch && _stochDPeriod != null) {
        indicatorParams = {'dPeriod': _stochDPeriod};
      }

      // Check for duplicate alert (only when creating new, not editing)
      if (widget.alert == null) {
        // Check alert limit before creating new alert
        final allCustomAlerts = await _alertRepository.getCustomAlerts();
        if (allCustomAlerts.length >= AppConstants.maxCustomAlerts) {
          if (mounted) {
            setState(() {
              _isLoading = false;
            });
            SnackBarHelper.showInfo(
              context,
              loc.t('create_alert_limit_reached', params: {'max': AppConstants.maxCustomAlerts.toString()}),
            );
          }
          return;
        }
        
        final allAlerts = await _alertRepository.getAlertsBySymbol(symbol);
        final existingAlerts = allAlerts
            .where((a) =>
                a.timeframe == _selectedTimeframe &&
                a.mode == _mode &&
                a.indicator == indicatorName &&
                a.period == _indicatorPeriod)
            .toList();

        // Check if there's an identical alert (same symbol, timeframe, mode, period, and levels)
        // Use enabled levels for duplicate check
        final enabledLevelsForCheck = <double>[];
        if (_lowerLevelEnabled && _levels.isNotEmpty) {
          enabledLevelsForCheck.add(_levels[0]);
        }
        if (_upperLevelEnabled && _levels.length > 1) {
          enabledLevelsForCheck.add(_levels[1]);
        }
        final sortedLevels = List.from(enabledLevelsForCheck)..sort();
        for (final existing in existingAlerts) {
          final existingSortedLevels = List.from(existing.levels)..sort();
          if (existingSortedLevels.length == sortedLevels.length &&
              existingSortedLevels
                  .every((level) => sortedLevels.contains(level)) &&
              sortedLevels
                  .every((level) => existingSortedLevels.contains(level))) {
            // Duplicate found
            if (mounted) {
              SnackBarHelper.showInfo(
                context,
                loc.t('create_alert_duplicate_error', params: {
                  'symbol': symbol,
                  'timeframe': _selectedTimeframe,
                }),
              );
            }
            return; // Don't save duplicate
          }
        }
      }

      // Read levels directly from controllers (validation already done by FormField validators)
      // Always send array with 2 elements: [lower, upper], where disabled level is null
      double? lowerLevel;
      double? upperLevel;
      
      if (_lowerLevelEnabled && _lowerLevelController.text.isNotEmpty) {
        lowerLevel = int.tryParse(_lowerLevelController.text)?.toDouble();
        debugPrint('Creating alert: Lower level from controller: ${_lowerLevelController.text} -> $lowerLevel');
      }
      
      if (_upperLevelEnabled && _upperLevelController.text.isNotEmpty) {
        upperLevel = int.tryParse(_upperLevelController.text)?.toDouble();
        debugPrint('Creating alert: Upper level from controller: ${_upperLevelController.text} -> $upperLevel');
      }
      
      debugPrint('Creating alert: Enabled levels: $lowerLevel, $upperLevel');
      debugPrint('Creating alert: _levels array: $_levels');
      
      final enabledLevels = <double?>[lowerLevel, upperLevel];
      
      if (enabledLevels[0] == null && enabledLevels[1] == null) {
        if (mounted) {
          setState(() {
            _isLoading = false;
          });
          context.showError(loc.t('create_alert_at_least_one_level_required'));
        }
        return;
      }

      final alert = widget.alert ?? AlertRule();
      alert.symbol = symbol;
      alert.timeframe = _selectedTimeframe;
      alert.indicator = indicatorName;
      alert.period = _indicatorPeriod;
      alert.indicatorParams = indicatorParams;
      // Filter out null values for storage (keep only enabled levels)
      alert.levels = enabledLevels.whereType<double>().toList();
      alert.mode = 'cross'; // Always use cross mode with one-way crossing
      alert.cooldownSec = _cooldownSec;
      alert.active = true;
      alert.soundEnabled = _soundEnabled;
      alert.alertOnClose = _alertOnClose;
      alert.description = _descriptionController.text.isEmpty
          ? null
          : _descriptionController.text;

      if (widget.alert == null) {
        alert.createdAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      }

      await _alertRepository.saveAlert(alert);
      // Pass enabled levels info to sync service so it can send proper array to server
      await AlertSyncService.syncAlert(alert,
        lowerLevelEnabled: _lowerLevelEnabled,
        upperLevelEnabled: _upperLevelEnabled,
        lowerLevelValue: lowerLevel,
        upperLevelValue: upperLevel,
      );

      if (mounted) {
        Navigator.pop(context, true);
        context.showSuccess(
          widget.alert == null
              ? loc.t('create_alert_created')
              : loc.t('create_alert_updated'),
        );
      }
    } catch (e) {
      // Log error to server
      final symbolForLog = _symbolController.text.trim().toUpperCase();
      ErrorService.logError(
        error: e,
        context: 'create_alert_screen_save_alert',
        symbol: symbolForLog,
      );
      
      if (mounted) {
        context.showError(ErrorService.getUserFriendlyError(e, context.loc));
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _deleteAlert() async {
    final loc = context.loc;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(loc.t('create_alert_delete_title')),
        content: Text(loc.t('create_alert_delete_message')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(loc.t('create_alert_cancel')),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: Text(loc.t('common_delete')),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await _alertRepository.deleteAlert(widget.alert!.id);
        await AlertSyncService.deleteAlert(widget.alert!);

        if (mounted) {
          Navigator.pop(context, true);
          context.showSuccess(loc.t('create_alert_deleted'));
        }
      } catch (e) {
        // Log error to server
        ErrorService.logError(
          error: e,
          context: 'create_alert_screen_delete_alert',
        );
        
        if (mounted) {
          context.showError(ErrorService.getUserFriendlyError(e, loc));
        }
      }
    }
  }
}
