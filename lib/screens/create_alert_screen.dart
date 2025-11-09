import 'package:flutter/material.dart';
import 'package:isar/isar.dart';
import '../models.dart';
import '../services/yahoo_proto.dart';
import '../localization/app_localizations.dart';

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
  int _rsiPeriod = 14;
  List<double> _levels = [30, 70];
  String _mode = 'cross';
  double _hysteresis = 0.5;
  int _cooldownSec = 600;
  bool _repeatable = true;
  bool _soundEnabled = true;
  bool _isLoading = false;
  bool _isSearchingSymbols = false;

  @override
  void initState() {
    super.initState();
    if (widget.alert != null) {
      _loadAlertData();
    }
  }

  void _loadAlertData() {
    final alert = widget.alert!;
    _symbolController.text = alert.symbol;
    _descriptionController.text = alert.description ?? '';
    _selectedTimeframe = alert.timeframe;
    _rsiPeriod = alert.rsiPeriod;
    _levels = List.from(alert.levels);
    _mode = alert.mode;
    _hysteresis = alert.hysteresis;
    _cooldownSec = alert.cooldownSec;
    _repeatable = alert.repeatable;
    _soundEnabled = alert.soundEnabled;
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
                  // Basic information
                  _buildBasicInfoCard(loc),
                  const SizedBox(height: 16),

                  // RSI settings
                  _buildRsiSettingsCard(loc),
                  const SizedBox(height: 16),

                  // Alert settings
                  _buildAlertSettingsCard(loc),
                  const SizedBox(height: 16),

                  // Advanced settings
                  _buildAdvancedSettingsCard(loc),
                  const SizedBox(height: 32),

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

                // If editing and symbol already selected and user is not editing - don't search
                if (widget.alert != null &&
                    query == widget.alert!.symbol &&
                    textEditingValue.selection.baseOffset ==
                        textEditingValue.selection.extentOffset) {
                  // User is not editing - don't show loading
                  return const Iterable<SymbolInfo>.empty();
                }

                if (query.isEmpty) {
                  // Show popular symbols if text is empty (only once)
                  if (!_isSearchingSymbols) {
                    if (mounted) {
                      setState(() {
                        _isSearchingSymbols = true;
                      });
                    }
                    try {
                      final popularSymbols =
                          await _yahooService.fetchPopularSymbols();
                      if (mounted) {
                        setState(() {
                          _isSearchingSymbols = false;
                        });
                      }
                      return popularSymbols.take(10).map((s) => SymbolInfo(
                            symbol: s,
                            name: s,
                            type: 'unknown',
                            currency: 'USD',
                            exchange: 'Unknown',
                          ));
                    } catch (e) {
                      if (mounted) {
                        setState(() {
                          _isSearchingSymbols = false;
                        });
                      }
                      return const Iterable<SymbolInfo>.empty();
                    }
                  }
                  return const Iterable<SymbolInfo>.empty();
                }

                if (query.length < 2) {
                  // Reset loading if query is too short
                  if (_isSearchingSymbols && mounted) {
                    setState(() {
                      _isSearchingSymbols = false;
                    });
                  }
                  return const Iterable<SymbolInfo>.empty();
                }

                // Search symbols on input (only if not already searching)
                if (!_isSearchingSymbols && mounted) {
                  setState(() {
                    _isSearchingSymbols = true;
                  });
                }

                try {
                  final results = await _yahooService.searchSymbols(query);
                  if (mounted) {
                    setState(() {
                      _isSearchingSymbols = false;
                    });
                  }
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
                    // Reset loading indicator if text changed and became short
                    if (_isSearchingSymbols && value.trim().length < 2) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) {
                          setState(() {
                            _isSearchingSymbols = false;
                          });
                        }
                      });
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
                );
              },
              onSelected: (SymbolInfo selection) {
                _symbolController.text = selection.symbol;
                FocusScope.of(context).unfocus();
              },
              optionsViewBuilder: (BuildContext context,
                  AutocompleteOnSelected<SymbolInfo> onSelected,
                  Iterable<SymbolInfo> options) {
                return Align(
                  alignment: Alignment.topLeft,
                  child: Material(
                    elevation: 4.0,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 200),
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
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          option.symbol,
                                          style: const TextStyle(
                                              fontWeight: FontWeight.bold),
                                        ),
                                        if (option.name != option.symbol)
                                          Text(
                                            option.name,
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: Colors.grey[600],
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                  if (option.type != 'unknown')
                                    Chip(
                                      label: Text(
                                        option.type,
                                        style: const TextStyle(fontSize: 10),
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
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              value: _selectedTimeframe,
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

  Widget _buildRsiSettingsCard(AppLocalizations loc) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              loc.t('create_alert_rsi_settings_title'),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    initialValue: _rsiPeriod.toString(),
                    decoration: InputDecoration(
                      labelText: loc.t('home_rsi_period_label'),
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.timeline),
                    ),
                    keyboardType: TextInputType.number,
                    onChanged: (value) {
                      _rsiPeriod = int.tryParse(value) ?? 14;
                    },
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: TextFormField(
                    initialValue: _hysteresis.toString(),
                    decoration: InputDecoration(
                      labelText: loc.t('create_alert_hysteresis_label'),
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.tune),
                    ),
                    keyboardType: TextInputType.number,
                    onChanged: (value) {
                      _hysteresis = double.tryParse(value) ?? 0.5;
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              loc.t('create_alert_levels_title'),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 8),
            _buildLevelsSelector(),
          ],
        ),
      ),
    );
  }

  Widget _buildLevelsSelector() {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: TextFormField(
                initialValue: _levels.isNotEmpty ? _levels[0].toString() : '30',
                decoration: InputDecoration(
                  labelText: context.loc.t('create_alert_lower_level'),
                  border: const OutlineInputBorder(),
                ),
                keyboardType: TextInputType.number,
                onChanged: (value) {
                  final lower = double.tryParse(value);
                  if (lower != null && _levels.isNotEmpty) {
                    setState(() {
                      _levels[0] = lower;
                    });
                  }
                },
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: TextFormField(
                initialValue: _levels.length > 1 ? _levels[1].toString() : '70',
                decoration: InputDecoration(
                  labelText: context.loc.t('create_alert_upper_level'),
                  border: const OutlineInputBorder(),
                ),
                keyboardType: TextInputType.number,
                onChanged: (value) {
                  final upper = double.tryParse(value);
                  if (upper != null) {
                    setState(() {
                      if (_levels.length > 1) {
                        _levels[1] = upper;
                      } else {
                        _levels.add(upper);
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
              value: _mode,
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
                      _cooldownSec = int.tryParse(value) ?? 600;
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

  Widget _buildAdvancedSettingsCard(AppLocalizations loc) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              loc.t('create_alert_advanced_title'),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Text(
              loc.t(
                'create_alert_hysteresis_value',
                params: {'value': _hysteresis.toStringAsFixed(1)},
              ),
              style: const TextStyle(fontSize: 16),
            ),
            Slider(
              value: _hysteresis,
              min: 0.1,
              max: 2.0,
              divisions: 19,
              label: _hysteresis.toStringAsFixed(1),
              onChanged: (value) {
                setState(() {
                  _hysteresis = value;
                });
              },
            ),
            const SizedBox(height: 16),
            Text(
              loc.t('create_alert_cooldown_value',
                  params: {'seconds': '$_cooldownSec'}),
              style: const TextStyle(fontSize: 16),
            ),
            Slider(
              value: _cooldownSec.toDouble(),
              min: 60,
              max: 3600,
              divisions: 59,
              label: loc.locale.languageCode == 'ru'
                  ? '$_cooldownSec сек'
                  : '$_cooldownSec sec',
              onChanged: (value) {
                setState(() {
                  _cooldownSec = value.round();
                });
              },
            ),
          ],
        ),
      ),
    );
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

      final alert = widget.alert ?? AlertRule();
      alert.symbol = symbol;
      alert.timeframe = _selectedTimeframe;
      alert.rsiPeriod = _rsiPeriod;
      alert.levels = List.from(_levels);
      alert.mode = _mode;
      alert.hysteresis = _hysteresis;
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
