import 'package:flutter/material.dart';
import 'package:isar/isar.dart';
import '../models.dart';
import '../services/yahoo_proto.dart';

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
    return Scaffold(
      appBar: AppBar(
        title: Text(
            widget.alert == null ? 'Создать алерт' : 'Редактировать алерт'),
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
                  // Основная информация
                  _buildBasicInfoCard(),
                  const SizedBox(height: 16),

                  // Настройки RSI
                  _buildRsiSettingsCard(),
                  const SizedBox(height: 16),

                  // Настройки алерта
                  _buildAlertSettingsCard(),
                  const SizedBox(height: 16),

                  // Дополнительные настройки
                  _buildAdvancedSettingsCard(),
                  const SizedBox(height: 32),

                  // Кнопки
                  _buildActionButtons(),
                ],
              ),
            ),
    );
  }

  Widget _buildBasicInfoCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Основная информация',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Autocomplete<SymbolInfo>(
              optionsBuilder: (TextEditingValue textEditingValue) async {
                final query = textEditingValue.text.trim();

                // Если при редактировании символ уже выбран и пользователь не редактирует - не ищем
                if (widget.alert != null &&
                    query == widget.alert!.symbol &&
                    textEditingValue.selection.baseOffset ==
                        textEditingValue.selection.extentOffset) {
                  // Пользователь не редактирует - не показываем загрузку
                  return const Iterable<SymbolInfo>.empty();
                }

                if (query.isEmpty) {
                  // Показываем популярные символы если текст пустой (только один раз)
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
                  // Сбрасываем загрузку если запрос слишком короткий
                  if (_isSearchingSymbols && mounted) {
                    setState(() {
                      _isSearchingSymbols = false;
                    });
                  }
                  return const Iterable<SymbolInfo>.empty();
                }

                // Ищем символы при вводе (только если еще не ищем)
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
                // Инициализируем контроллер только один раз при редактировании
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
                    labelText: 'Символ',
                    hintText: 'Начните вводить символ (например, AAPL)',
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
                    // Сбрасываем индикатор загрузки, если текст изменен и стал коротким
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
                      return 'Выберите или введите символ';
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
              decoration: const InputDecoration(
                labelText: 'ТФ',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.schedule),
              ),
              items: const [
                DropdownMenuItem(value: '1m', child: Text('1м')),
                DropdownMenuItem(value: '5m', child: Text('5м')),
                DropdownMenuItem(value: '15m', child: Text('15м')),
                DropdownMenuItem(value: '1h', child: Text('1ч')),
                DropdownMenuItem(value: '4h', child: Text('4ч')),
                DropdownMenuItem(value: '1d', child: Text('1д')),
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
              decoration: const InputDecoration(
                labelText: 'Описание (необязательно)',
                hintText: 'Краткое описание алерта',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.description),
              ),
              maxLines: 2,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRsiSettingsCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Настройки RSI',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    initialValue: _rsiPeriod.toString(),
                    decoration: const InputDecoration(
                      labelText: 'Период RSI',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.timeline),
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
                    decoration: const InputDecoration(
                      labelText: 'Гистерезис',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.tune),
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
            const Text(
              'Уровни RSI',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
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
                decoration: const InputDecoration(
                  labelText: 'Нижний уровень',
                  border: OutlineInputBorder(),
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
                decoration: const InputDecoration(
                  labelText: 'Верхний уровень',
                  border: OutlineInputBorder(),
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
            _buildPresetButton('30/70', [30, 70]),
            _buildPresetButton('20/80', [20, 80]),
            _buildPresetButton('25/75', [25, 75]),
            _buildPresetButton('50', [50]),
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

  Widget _buildAlertSettingsCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Настройки алерта',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              value: _mode,
              decoration: const InputDecoration(
                labelText: 'Тип алерта',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.notifications),
              ),
              items: const [
                DropdownMenuItem(
                    value: 'cross', child: Text('Пересечение уровня')),
                DropdownMenuItem(value: 'enter', child: Text('Вход в зону')),
                DropdownMenuItem(value: 'exit', child: Text('Выход из зоны')),
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
                    decoration: const InputDecoration(
                      labelText: 'Кулдаун (сек)',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.timer),
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
              title: const Text('Повторяющийся'),
              subtitle: const Text('Алерт может срабатывать многократно'),
              value: _repeatable,
              onChanged: (value) {
                setState(() {
                  _repeatable = value;
                });
              },
            ),
            SwitchListTile(
              title: const Text('Звук'),
              subtitle: const Text('Включить звуковое уведомление'),
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

  Widget _buildAdvancedSettingsCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Дополнительные настройки',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            const Text(
              'Гистерезис: ${0.5}',
              style: TextStyle(fontSize: 16),
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
              'Кулдаун: $_cooldownSec сек',
              style: const TextStyle(fontSize: 16),
            ),
            Slider(
              value: _cooldownSec.toDouble(),
              min: 60,
              max: 3600,
              divisions: 59,
              label: '$_cooldownSec сек',
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

  Widget _buildActionButtons() {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: ElevatedButton(
            onPressed: _saveAlert,
            child: Text(widget.alert == null ? 'Создать' : 'Сохранить'),
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
      // Валидация символа
      final symbol = _symbolController.text.trim().toUpperCase();
      if (symbol.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('Пожалуйста, выберите или введите символ')),
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
              widget.alert == null ? 'Алерт создан' : 'Алерт обновлен',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка: $e')),
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить алерт'),
        content: const Text('Вы уверены, что хотите удалить этот алерт?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Удалить'),
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
            const SnackBar(content: Text('Алерт удален')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Ошибка: $e')),
          );
        }
      }
    }
  }
}
