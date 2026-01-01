import 'package:flutter/material.dart';
import 'package:isar/isar.dart';
import '../models.dart';
import '../models/indicator_type.dart';
import '../services/yahoo_proto.dart';
import '../services/alert_sync_service.dart';
import '../services/symbol_search_service.dart';
import '../localization/app_localizations.dart';
import '../state/app_state.dart';
import '../widgets/indicator_selector.dart';

class CreateAlertScreen extends StatefulWidget {
  final Isar isar;
  final AlertRule? alert;

  const CreateAlertScreen({
    super.key,
    required this.isar,
    this.alert,
  });

  @override
  State<CreateAlertScreen> createState() => _CreateAlertScreenState();
}

class _CreateAlertScreenState extends State<CreateAlertScreen> {
  final _formKey = GlobalKey<FormState>();
  final _symbolController = TextEditingController();
  final _descriptionController = TextEditingController();
  final YahooProtoSource _yahooService =
      YahooProtoSource('https://rsi-workers.vovan4ikukraine.workers.dev');

  String _selectedTimeframe = '15m';
  int _indicatorPeriod = 14;
  int? _stochDPeriod; // Stochastic %D period
  List<double> _levels = [30, 70];
  String _mode = 'cross';
  int _cooldownSec = 600;
  bool _repeatable = true;
  bool _soundEnabled = true;
  bool _isLoading = false;
  bool _isSearchingSymbols = false;
  late final SymbolSearchService _symbolSearchService;
  List<SymbolInfo> _popularSymbols = [];
  AppState? _appState;

  @override
  void initState() {
    super.initState();
    _symbolSearchService = SymbolSearchService(_yahooService);
    _loadPopularSymbols();
    if (widget.alert != null) {
      _loadAlertData();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _appState = AppStateScope.of(context);
    // If creating new alert, use selected indicator
    if (widget.alert == null && _appState != null) {
      final indicatorType = _appState!.selectedIndicator;
      _indicatorPeriod = indicatorType.defaultPeriod;
      _levels = List.from(indicatorType.defaultLevels);
      if (indicatorType == IndicatorType.stoch) {
        _stochDPeriod = 3;
      }
    }
  }

  void _loadAlertData() {
    final alert = widget.alert!;
    _symbolController.text = alert.symbol;
    _descriptionController.text = alert.description ?? '';
    _selectedTimeframe = alert.timeframe;
    _indicatorPeriod = alert.period;
    _levels = List.from(alert.levels);
    _mode = alert.mode;
    _cooldownSec = alert.cooldownSec;
    _repeatable = alert.repeatable;
    _soundEnabled = alert.soundEnabled;

    // Load indicator-specific parameters
    if (alert.indicatorParams != null) {
      final params = alert.indicatorParams!;
      if (params.containsKey('dPeriod')) {
        _stochDPeriod = params['dPeriod'] as int?;
      }
    }
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
  void dispose() {
    _symbolController.dispose();
    _descriptionController.dispose();
    _symbolSearchService.cancelPending();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.alert == null
            ? loc.t('create_alert_title_new')
            : loc.t('create_alert_title_edit')),
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
                  _buildIndicatorSettingsCard(loc),
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
                // Initialize controller only once when editing
                if (widget.alert != null && _symbolController.text.isNotEmpty) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (textEditingController.text != _symbolController.text) {
                      textEditingController.text = _symbolController.text;
                    }
                  });
                }

                return TextFormField(
                  controller: textEditingController,
                  focusNode: focusNode,
                  decoration: InputDecoration(
                    labelText: loc.t('home_symbol_label'),
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
                    _symbolController.text = value;
                  },
                  validator: (value) {
                    if (value == null ||
                        value.isEmpty ||
                        value.trim().isEmpty) {
                      return loc.t('create_alert_symbol_error');
                    }
                    return null;
                  },
                );
              },
              onSelected: (SymbolInfo selection) {
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
            DropdownButtonFormField<String>(
              initialValue: _selectedTimeframe,
              decoration: InputDecoration(
                labelText: loc.t('home_timeframe_label'),
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.schedule),
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
            const SizedBox(height: 16),
            TextFormField(
              controller: _descriptionController,
              decoration: InputDecoration(
                labelText: loc.t('create_alert_description_label'),
                hintText: loc.t('create_alert_description_hint'),
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.description),
              ),
              maxLines: 2,
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
              '${indicatorType.name} Settings',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    initialValue: _indicatorPeriod.toString(),
                    decoration: InputDecoration(
                      labelText: () {
                        switch (indicatorType) {
                          case IndicatorType.stoch:
                            return loc.t('home_stoch_k_period_label');
                          case IndicatorType.williams:
                            return loc.t('home_wpr_period_label');
                          case IndicatorType.rsi:
                            return loc.t('home_period_label');
                        }
                      }(),
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.timeline),
                    ),
                    keyboardType: TextInputType.number,
                    onChanged: (value) {
                      final period = int.tryParse(value);
                      if (period != null && period >= 1 && period <= 100) {
                        setState(() {
                          _indicatorPeriod = period;
                        });
                      }
                    },
                  ),
                ),
                if (indicatorType == IndicatorType.stoch) ...[
                  const SizedBox(width: 16),
                  Expanded(
                    child: TextFormField(
                      initialValue: (_stochDPeriod ?? 3).toString(),
                      decoration: InputDecoration(
                        labelText: loc.t('home_stoch_d_period_label'),
                        border: const OutlineInputBorder(),
                        prefixIcon: Icon(Icons.timeline),
                      ),
                      keyboardType: TextInputType.number,
                      onChanged: (value) {
                        final dPeriod = int.tryParse(value);
                        if (dPeriod != null && dPeriod >= 1 && dPeriod <= 100) {
                          setState(() {
                            _stochDPeriod = dPeriod;
                          });
                        }
                      },
                    ),
                  ),
                ],
              ],
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
        Row(
          children: [
            Expanded(
              child: TextFormField(
                initialValue: _levels.isNotEmpty
                    ? _levels[0].toString()
                    : defaultLevels.first.toString(),
                decoration: InputDecoration(
                  labelText: context.loc.t('create_alert_lower_level'),
                  border: const OutlineInputBorder(),
                ),
                keyboardType: TextInputType.number,
                onChanged: (value) {
                  final lower = double.tryParse(value);
                  if (lower != null &&
                      lower >= 0 &&
                      lower <= 100 &&
                      _levels.isNotEmpty) {
                    setState(() {
                      _levels[0] = lower.clamp(0.0, 100.0);
                    });
                  }
                },
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: TextFormField(
                initialValue: _levels.length > 1
                    ? _levels[1].toString()
                    : (defaultLevels.length > 1
                        ? defaultLevels[1].toString()
                        : '100'),
                decoration: InputDecoration(
                  labelText: context.loc.t('create_alert_upper_level'),
                  border: const OutlineInputBorder(),
                ),
                keyboardType: TextInputType.number,
                onChanged: (value) {
                  final upper = double.tryParse(value);
                  if (upper != null && upper >= 0 && upper <= 100) {
                    setState(() {
                      if (_levels.length > 1) {
                        _levels[1] = upper.clamp(0.0, 100.0);
                      } else {
                        _levels.add(upper.clamp(0.0, 100.0));
                      }
                    });
                  }
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            _buildPresetButton(
                context.loc.t('create_alert_presets_3070'), [30, 70]),
            _buildPresetButton(
                context.loc.t('create_alert_presets_2080'), [20, 80]),
            _buildPresetButton(
                context.loc.t('create_alert_presets_2575'), [25, 75]),
            _buildPresetButton(context.loc.t('create_alert_presets_50'), [50]),
          ],
        ),
      ],
    );
  }

  Widget _buildPresetButton(String label, List<double> levels) {
    return OutlinedButton(
      onPressed: () {
        setState(() {
          _levels = List.from(levels);
        });
      },
      child: Text(label),
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
            DropdownButtonFormField<String>(
              initialValue: _mode,
              decoration: InputDecoration(
                labelText: loc.t('create_alert_type_label'),
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.notifications),
              ),
              items: [
                DropdownMenuItem(
                  value: 'cross',
                  child: Text(loc.t('create_alert_type_cross')),
                ),
                DropdownMenuItem(
                  value: 'enter',
                  child: Text(loc.t('create_alert_type_enter')),
                ),
                DropdownMenuItem(
                  value: 'exit',
                  child: Text(loc.t('create_alert_type_exit')),
                ),
              ],
              onChanged: (value) {
                if (value != null) {
                  setState(() {
                    _mode = value;
                  });
                }
              },
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    initialValue: _cooldownSec.toString(),
                    decoration: InputDecoration(
                      labelText: loc.t('create_alert_cooldown_label'),
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.timer),
                    ),
                    keyboardType: TextInputType.number,
                    onChanged: (value) {
                      final cooldown = int.tryParse(value);
                      if (cooldown != null &&
                          cooldown >= 0 &&
                          cooldown <= 86400) {
                        _cooldownSec = cooldown;
                      }
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            SwitchListTile(
              title: Text(loc.t('create_alert_repeatable')),
              subtitle: Text(loc.t('create_alert_repeatable_sub')),
              value: _repeatable,
              onChanged: (value) {
                setState(() {
                  _repeatable = value;
                });
              },
            ),
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
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(loc.t('create_alert_symbol_error'))),
          );
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
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                    'Symbol "$symbol" not found. Please enter a valid symbol.'),
                backgroundColor: Colors.red,
                duration: const Duration(seconds: 3),
              ),
            );
          }
          return;
        }
      } catch (e) {
        // If validation fails, still allow creation but show warning
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                  'Could not validate symbol "$symbol". Please verify it exists.'),
              backgroundColor: Colors.orange,
              duration: const Duration(seconds: 3),
            ),
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
        // Note: Isar doesn't support filtering by indicator field directly,
        // so we'll filter in memory after fetching
        final allAlerts = await widget.isar.alertRules
            .filter()
            .symbolEqualTo(symbol)
            .timeframeEqualTo(_selectedTimeframe)
            .modeEqualTo(_mode)
            .findAll();

        final existingAlerts = allAlerts
            .where((a) =>
                a.indicator == indicatorName && a.period == _indicatorPeriod)
            .toList();

        // Check if there's an identical alert (same symbol, timeframe, mode, period, and levels)
        final sortedLevels = List.from(_levels)..sort();
        for (final existing in existingAlerts) {
          final existingSortedLevels = List.from(existing.levels)..sort();
          if (existingSortedLevels.length == sortedLevels.length &&
              existingSortedLevels
                  .every((level) => sortedLevels.contains(level)) &&
              sortedLevels
                  .every((level) => existingSortedLevels.contains(level))) {
            // Duplicate found
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    loc.t('create_alert_duplicate_error', params: {
                      'symbol': symbol,
                      'timeframe': _selectedTimeframe,
                    }),
                  ),
                  backgroundColor: Colors.orange,
                  duration: const Duration(seconds: 3),
                ),
              );
            }
            return; // Don't save duplicate
          }
        }
      }

      final alert = widget.alert ?? AlertRule();
      alert.symbol = symbol;
      alert.timeframe = _selectedTimeframe;
      alert.indicator = indicatorName;
      alert.period = _indicatorPeriod;
      alert.indicatorParams = indicatorParams;
      alert.levels = List.from(_levels);
      alert.mode = _mode;
      alert.cooldownSec = _cooldownSec;
      alert.active = true;
      alert.repeatable = _repeatable;
      alert.soundEnabled = _soundEnabled;
      alert.description = _descriptionController.text.isEmpty
          ? null
          : _descriptionController.text;

      if (widget.alert == null) {
        alert.createdAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      }

      await widget.isar.writeTxn(() {
        return widget.isar.alertRules.put(alert);
      });
      await AlertSyncService.syncAlert(widget.isar, alert);

      if (mounted) {
        Navigator.pop(context, true);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.alert == null
                  ? loc.t('create_alert_created')
                  : loc.t('create_alert_updated'),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        final loc = context.loc;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              loc.t('alerts_error_generic', params: {'message': '$e'}),
            ),
          ),
        );
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
        await widget.isar.writeTxn(() {
          return widget.isar.alertRules.delete(widget.alert!.id);
        });
        await AlertSyncService.deleteAlert(widget.alert!);

        if (mounted) {
          Navigator.pop(context, true);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(loc.t('create_alert_deleted'))),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                loc.t('alerts_error_generic', params: {'message': '$e'}),
              ),
            ),
          );
        }
      }
    }
  }
}
