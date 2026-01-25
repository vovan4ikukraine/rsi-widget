# Быстрый старт рефакторинга

## Созданные файлы

### 1. Константы
- `lib/constants/app_constants.dart` - все магические числа и строки

### 2. Утилиты
- `lib/utils/snackbar_helper.dart` - единый способ показа сообщений
- `lib/utils/indicator_level_validator.dart` - валидация уровней
- `lib/utils/context_extensions.dart` - расширения для BuildContext

### 3. Виджеты
- `lib/widgets/wpr_level_input_formatter.dart` - единый форматтер для WPR

### 4. Репозитории
- `lib/repositories/alert_repository.dart` - пример репозитория для работы с алертами

## Как использовать

### 1. Замена SnackBar

**Было:**
```dart
if (mounted) {
  final loc = context.loc;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(loc.t('error_message')),
      backgroundColor: Colors.red,
    ),
  );
}
```

**Стало:**
```dart
context.showError(context.loc.t('error_message'));
// или
SnackBarHelper.showError(context, context.loc.t('error_message'));
```

### 2. Замена WprLevelInputFormatter

**Было:** Дублирование в каждом файле

**Стало:**
```dart
import '../widgets/wpr_level_input_formatter.dart';

// В TextFormField
inputFormatters: indicatorType == IndicatorType.williams
    ? [WprLevelInputFormatter()]
    : [FilteringTextInputFormatter.allow(RegExp(r'[0-9]'))],
```

### 3. Использование валидатора

**Было:**
```dart
validator: (value) {
  if (!_lowerLevelEnabled) return null;
  if (value == null || value.isEmpty) return ' ';
  final lower = int.tryParse(value)?.toDouble();
  if (lower == null) return ' ';
  final isWilliams = indicatorType == IndicatorType.williams;
  final minRange = isWilliams ? -99.0 : 1.0;
  final maxRange = isWilliams ? -1.0 : 99.0;
  if (lower < minRange || lower > maxRange) return ' ';
  // ... еще проверки
}
```

**Стало:**
```dart
import '../utils/indicator_level_validator.dart';

validator: (value) => IndicatorLevelValidator.validateLevel(
  value,
  indicatorType,
  _lowerLevelEnabled,
  otherLevel: _upperLevelEnabled ? _upperLevel : null,
  isLower: true,
),
```

### 4. Использование констант

**Было:**
```dart
if (allExistingItems.length >= 30) { ... }
final limit = periodBuffer > 100 ? periodBuffer : 100;
```

**Стало:**
```dart
import '../constants/app_constants.dart';

if (allExistingItems.length >= AppConstants.maxWatchlistItems) { ... }
final limit = periodBuffer > AppConstants.minCandlesForChart 
    ? periodBuffer 
    : AppConstants.minCandlesForChart;
```

### 5. Использование репозитория

**Было:**
```dart
await widget.isar.writeTxn(() {
  return widget.isar.alertRules.put(alert);
});
final alerts = await widget.isar.alertRules.where().findAll();
```

**Стало:**
```dart
final alertRepository = AlertRepository(widget.isar);
await alertRepository.saveAlert(alert);
final alerts = await alertRepository.getAllAlerts();
```

## План миграции

### Шаг 1: Импорты
Добавьте в начало файлов:
```dart
import '../constants/app_constants.dart';
import '../utils/snackbar_helper.dart';
import '../utils/context_extensions.dart';
import '../utils/indicator_level_validator.dart';
import '../widgets/wpr_level_input_formatter.dart';
```

### Шаг 2: Замена по одному файлу
Начните с одного файла (например, `create_alert_screen.dart`):
1. Удалите дублированный `WprLevelInputFormatter`
2. Замените все `ScaffoldMessenger` на `context.showError/Success`
3. Замените валидацию на `IndicatorLevelValidator`
4. Замените магические числа на константы

### Шаг 3: Тестирование
После каждого файла проверьте, что все работает.

### Шаг 4: Повторите для остальных файлов
- `home_screen.dart`
- `watchlist_screen.dart`
- `alerts_screen.dart`
- и т.д.

## Преимущества

✅ **Меньше кода** - убрано дублирование
✅ **Легче поддерживать** - изменения в одном месте
✅ **Меньше ошибок** - единая логика
✅ **Читабельнее** - понятные имена методов
✅ **Тестируемость** - утилиты легко тестировать

## Следующие шаги

После применения быстрых исправлений:
1. Разделить большие экраны на компоненты
2. Внедрить Dependency Injection
3. Добавить unit-тесты

См. `REFACTORING_RECOMMENDATIONS.md` для полного плана.
