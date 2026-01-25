# Рекомендации по рефакторингу перед релизом

## Анализ кода на соответствие DRY, SOLID, KISS

### 🔴 Критические проблемы

#### 1. DRY (Don't Repeat Yourself) - Нарушения

##### 1.1 Дублирование `WprLevelInputFormatter`
**Проблема:** Класс дублируется в 3 файлах:
- `lib/screens/home_screen.dart` (строки 45-93)
- `lib/screens/watchlist_screen.dart` (строки 32-79)
- `lib/screens/create_alert_screen.dart` (строки 34-82)

**Решение:**
```dart
// Создать lib/widgets/wpr_level_input_formatter.dart
class WprLevelInputFormatter extends TextInputFormatter {
  // Единая реализация
}
```

##### 1.2 Дублирование логики показа SnackBar
**Проблема:** Повторяющийся код для показа ошибок/успеха:
```dart
// Встречается 20+ раз в разных файлах
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

**Решение:** Создать утилитный класс:
```dart
// lib/utils/snackbar_helper.dart
class SnackBarHelper {
  static void showError(BuildContext context, String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 3),
      ),
    );
  }
  
  static void showSuccess(BuildContext context, String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.green,
        duration: const Duration(seconds: 2),
      ),
    );
  }
  
  static void showLoading(BuildContext context, String message) {
    if (!context.mounted) return;
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
            Text(message),
          ],
        ),
        duration: const Duration(seconds: 30),
      ),
    );
  }
}
```

##### 1.3 Дублирование валидации уровней индикаторов
**Проблема:** Логика валидации уровней повторяется в:
- `create_alert_screen.dart`
- `watchlist_screen.dart` (для массовых алертов)

**Решение:** Создать валидатор:
```dart
// lib/utils/indicator_level_validator.dart
class IndicatorLevelValidator {
  static String? validateLevel(
    String? value,
    IndicatorType indicatorType,
    bool isEnabled,
    {double? otherLevel, bool isLower = true}
  ) {
    if (!isEnabled) return null;
    if (value == null || value.isEmpty) return ' ';
    
    final level = int.tryParse(value)?.toDouble();
    if (level == null) return ' ';
    
    final isWilliams = indicatorType == IndicatorType.williams;
    final minRange = isWilliams ? -99.0 : 1.0;
    final maxRange = isWilliams ? -1.0 : 99.0;
    
    if (level < minRange || level > maxRange) return ' ';
    
    if (otherLevel != null) {
      if (isLower && level >= otherLevel) return ' ';
      if (!isLower && level <= otherLevel) return ' ';
    }
    
    return null;
  }
}
```

##### 1.4 Дублирование логики работы с Isar транзакциями
**Проблема:** Повторяющийся паттерн:
```dart
await widget.isar.writeTxn(() {
  return widget.isar.alertRules.put(alert);
});
```

**Решение:** Создать репозиторий:
```dart
// lib/repositories/alert_repository.dart
class AlertRepository {
  final Isar isar;
  
  AlertRepository(this.isar);
  
  Future<void> saveAlert(AlertRule alert) async {
    await isar.writeTxn(() => isar.alertRules.put(alert));
  }
  
  Future<void> deleteAlert(int id) async {
    await isar.writeTxn(() => isar.alertRules.delete(id));
  }
  
  Future<List<AlertRule>> getAllAlerts() async {
    return await isar.alertRules.where().findAll();
  }
}
```

##### 1.5 Дублирование логики сохранения/загрузки состояния
**Проблема:** Похожая логика в `home_screen.dart` и `watchlist_screen.dart`

**Решение:** Создать базовый класс или миксин:
```dart
// lib/mixins/screen_state_mixin.dart
mixin ScreenStateMixin<T extends StatefulWidget> on State<T> {
  Future<void> saveIndicatorSettings({
    required String screenPrefix,
    required String timeframe,
    required int period,
    required double lowerLevel,
    required double upperLevel,
    required IndicatorType indicatorType,
    int? stochDPeriod,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('${screenPrefix}_timeframe', timeframe);
    await prefs.setInt('${screenPrefix}_${indicatorType.toJson()}_period', period);
    await prefs.setDouble('${screenPrefix}_${indicatorType.toJson()}_lower_level', lowerLevel);
    await prefs.setDouble('${screenPrefix}_${indicatorType.toJson()}_upper_level', upperLevel);
    if (indicatorType == IndicatorType.stoch && stochDPeriod != null) {
      await prefs.setInt('${screenPrefix}_stoch_d_period', stochDPeriod);
    }
  }
}
```

---

#### 2. SOLID - Нарушения

##### 2.1 Single Responsibility Principle (SRP)

**Проблема:** Огромные классы с множественными обязанностями:

- `WatchlistScreen` (3135 строк) - управление UI, бизнес-логика, работа с БД, валидация
- `HomeScreen` (1984 строки) - аналогично
- `CreateAlertScreen` - UI, валидация, сохранение, синхронизация

**Решение:** Разделить на компоненты:

```dart
// lib/screens/watchlist/watchlist_screen.dart (только UI)
class WatchlistScreen extends StatefulWidget { ... }

// lib/screens/watchlist/watchlist_controller.dart (бизнес-логика)
class WatchlistController {
  final WatchlistRepository repository;
  final AlertRepository alertRepository;
  final IndicatorService indicatorService;
  
  Future<void> loadWatchlist() async { ... }
  Future<void> createMassAlerts(...) async { ... }
}

// lib/screens/watchlist/watchlist_view_model.dart (состояние)
class WatchlistViewModel extends ChangeNotifier {
  List<WatchlistItem> items = [];
  bool isLoading = false;
  // ...
}
```

##### 2.2 Open/Closed Principle (OCP)

**Проблема:** Жесткая привязка к конкретным реализациям:
```dart
final YahooProtoSource _yahooService = YahooProtoSource('...');
```

**Решение:** Использовать интерфейсы:
```dart
// lib/services/data_source.dart
abstract class DataSource {
  Future<List<Candle>> fetchCandles(String symbol, String timeframe, {int? limit});
}

// lib/services/yahoo_proto.dart
class YahooProtoSource implements DataSource { ... }

// В экранах
final DataSource dataSource = YahooProtoSource('...');
```

##### 2.3 Dependency Inversion Principle (DIP)

**Проблема:** Прямые зависимости от конкретных классов

**Решение:** Dependency Injection:
```dart
// lib/di/service_locator.dart
class ServiceLocator {
  static final _instance = ServiceLocator._();
  factory ServiceLocator() => _instance;
  ServiceLocator._();
  
  DataSource get dataSource => YahooProtoSource('...');
  AlertRepository get alertRepository => AlertRepository(Isar.getInstance());
}
```

---

#### 3. KISS (Keep It Simple, Stupid) - Нарушения

##### 3.1 Слишком сложные методы

**Проблема:** Методы с большим количеством строк и вложенности:

- `_createMassAlerts()` в `watchlist_screen.dart` - 300+ строк
- `_loadIndicatorData()` в `home_screen.dart` - 150+ строк

**Решение:** Разбить на меньшие методы:

```dart
// Было:
Future<void> _createMassAlerts() async {
  // 300 строк кода
}

// Стало:
Future<void> _createMassAlerts() async {
  if (!_validateMassAlertSettings()) return;
  
  final alerts = await _prepareMassAlerts();
  await _saveMassAlerts(alerts);
  await _syncMassAlerts(alerts);
  _showSuccessMessage(alerts.length);
}

bool _validateMassAlertSettings() { ... }
Future<List<AlertRule>> _prepareMassAlerts() async { ... }
Future<void> _saveMassAlerts(List<AlertRule> alerts) async { ... }
Future<void> _syncMassAlerts(List<AlertRule> alerts) async { ... }
void _showSuccessMessage(int count) { ... }
```

##### 3.2 Избыточная вложенность условий

**Проблема:** Много вложенных if-ов:
```dart
if (mounted) {
  if (condition1) {
    if (condition2) {
      // код
    }
  }
}
```

**Решение:** Early returns и guard clauses:
```dart
if (!mounted) return;
if (!condition1) return;
if (!condition2) return;
// код
```

##### 3.3 Магические числа и строки

**Проблема:** Хардкод значений:
```dart
if (allExistingItems.length >= 30) { ... }
final limit = periodBuffer > baseMinimum ? periodBuffer : baseMinimum;
```

**Решение:** Константы:
```dart
class AppConstants {
  static const int maxWatchlistItems = 30;
  static const int minCandlesForChart = 100;
  static const int periodBuffer = 20;
  static const int defaultCooldownSec = 600;
}
```

---

### 🟡 Важные оптимизации

#### 1. Производительность

##### 1.1 Избыточные перерисовки
**Проблема:** `setState()` вызывается слишком часто

**Решение:** Использовать `ValueNotifier` и `Consumer`:
```dart
final _isLoading = ValueNotifier<bool>(false);

// В UI
ValueListenableBuilder<bool>(
  valueListenable: _isLoading,
  builder: (context, isLoading, child) {
    return isLoading ? CircularProgressIndicator() : child!;
  },
)
```

##### 1.2 Неоптимальные запросы к БД
**Проблема:** Множественные запросы вместо одного

**Решение:** Batch операции:
```dart
// Было:
for (final alert in alerts) {
  await isar.alertRules.put(alert);
}

// Стало:
await isar.writeTxn(() {
  for (final alert in alerts) {
    isar.alertRules.put(alert);
  }
});
```

#### 2. Обработка ошибок

**Проблема:** Непоследовательная обработка ошибок

**Решение:** Единый обработчик:
```dart
// lib/utils/error_handler.dart
class ErrorHandler {
  static Future<T> handleAsync<T>(
    BuildContext context,
    Future<T> Function() action, {
    String? errorMessage,
  }) async {
    try {
      return await action();
    } catch (e) {
      ErrorService.logError(error: e, context: errorMessage);
      if (context.mounted) {
        SnackBarHelper.showError(
          context,
          errorMessage ?? ErrorService.getUserFriendlyError(e, context.loc),
        );
      }
      rethrow;
    }
  }
}
```

---

### 📋 План рефакторинга (приоритеты)

#### Фаза 1: Критические исправления (1-2 дня)
1. ✅ Вынести `WprLevelInputFormatter` в отдельный файл
2. ✅ Создать `SnackBarHelper` для унификации показа сообщений
3. ✅ Создать `IndicatorLevelValidator` для валидации
4. ✅ Вынести константы в `AppConstants`

#### Фаза 2: Репозитории и сервисы (2-3 дня)
1. ✅ Создать репозитории для работы с БД
2. ✅ Рефакторинг больших методов (разбить на меньшие)
3. ✅ Улучшить обработку ошибок

#### Фаза 3: Архитектурные улучшения (3-5 дней)
1. ✅ Разделить большие экраны на контроллеры/ViewModel
2. ✅ Внедрить Dependency Injection
3. ✅ Создать интерфейсы для сервисов

#### Фаза 4: Оптимизация (1-2 дня)
1. ✅ Оптимизировать перерисовки
2. ✅ Оптимизировать запросы к БД
3. ✅ Добавить кэширование где необходимо

---

### 📝 Чеклист перед релизом

- [ ] Все дублирование кода устранено
- [ ] Большие классы разделены на компоненты
- [ ] Все магические числа вынесены в константы
- [ ] Единая обработка ошибок
- [ ] Оптимизированы запросы к БД
- [ ] Добавлены unit-тесты для критичных компонентов
- [ ] Проведен code review
- [ ] Документация обновлена

---

### 🔧 Быстрые исправления (можно сделать сразу)

1. **Вынести константы:**
```dart
// lib/constants/app_constants.dart
class AppConstants {
  static const int maxWatchlistItems = 30;
  static const int minCandlesForChart = 100;
  static const int periodBuffer = 20;
  static const int defaultCooldownSec = 600;
  static const String watchlistAlertPrefix = 'WATCHLIST:';
}
```

2. **Создать утилиты для работы с контекстом:**
```dart
// lib/utils/context_extensions.dart
extension ContextExtensions on BuildContext {
  void showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(this).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }
  
  void showSuccess(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(this).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.green),
    );
  }
}
```

3. **Упростить проверки mounted:**
```dart
// lib/utils/mounted_guard.dart
extension MountedGuard on State {
  bool get isMounted => mounted;
  
  T? guard<T>(T Function() action) {
    if (!mounted) return null;
    return action();
  }
}
```

---

## Заключение

Основные проблемы:
1. **DRY:** Много дублирования кода (форматтеры, валидация, SnackBar)
2. **SOLID:** Нарушение SRP (огромные классы), жесткие зависимости
3. **KISS:** Слишком сложные методы, избыточная вложенность

Рекомендуется начать с Фазы 1 (быстрые исправления), которые дадут максимальный эффект при минимальных затратах времени.
