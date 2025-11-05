# RSI Widget App

Мобильное приложение для RSI алертов и виджетов на iOS и Android.

## Описание

RSI Widget App - это кросс-платформенное мобильное приложение, которое:
- Показывает график RSI выбранного инструмента (акции, крипто, FX)
- Присылает уведомления при пересечении заданных уровней RSI
- Работает автономно в формате виджета на экране телефона
- Поддерживает iOS и Android с единым кодом

## Функции

### Основные возможности
- **RSI График**: Отображение RSI с настраиваемыми уровнями (30/70, 20/80, пользовательские)
- **Алерты**: Уведомления при пересечении уровней RSI с гистерезисом
- **Виджеты**: iOS WidgetKit и Android AppWidget с мини-графиками
- **Множественные инструменты**: Акции, форекс, криптовалюты
- **Таймфреймы**: 1m, 5m, 15m, 1h, 4h, 1d

### Технические особенности
- **Кросс-платформа**: Flutter для iOS и Android
- **Локальная база данных**: Isar для кэширования данных
- **Push уведомления**: Firebase Cloud Messaging
- **Бэкенд**: Cloudflare Workers с D1 базой данных
- **Источники данных**: Yahoo Finance (бесплатно)

## Архитектура

### Клиент (Flutter)
- **UI**: Material Design с темной темой
- **Графики**: fl_chart для отображения RSI
- **База данных**: Isar для локального хранения
- **Уведомления**: flutter_local_notifications + Firebase

### Бэкенд (Cloudflare Workers)
- **Cron задачи**: Проверка алертов каждую минуту
- **RSI Engine**: Расчет RSI по алгоритму Wilder
- **FCM**: Отправка push уведомлений
- **База данных**: D1 (SQLite) для хранения правил

### Виджеты
- **iOS**: WidgetKit с SwiftUI
- **Android**: AppWidget с RemoteViews

## Установка

### Требования
- Flutter 3.3.0+
- Dart 3.0+
- iOS 12.0+ / Android API 21+
- Firebase проект
- Cloudflare Workers аккаунт

### Настройка проекта

1. **Клонирование репозитория**
```bash
git clone https://github.com/your-repo/rsi-widget-app.git
cd rsi-widget-app
```

2. **Установка зависимостей**
```bash
flutter pub get
```

3. **Генерация кода**
```bash
flutter packages pub run build_runner build
```

### Настройка Firebase

1. Создайте проект в [Firebase Console](https://console.firebase.google.com)
2. Добавьте iOS и Android приложения
3. Скачайте конфигурационные файлы:
   - `ios/Runner/GoogleService-Info.plist`
   - `android/app/google-services.json`
4. Включите Cloud Messaging в консоли Firebase

### Настройка Cloudflare Workers

1. Установите Wrangler CLI:
```bash
npm install -g wrangler
```

2. Войдите в аккаунт:
```bash
wrangler login
```

3. Создайте D1 базу данных:
```bash
wrangler d1 create rsi-db
```

4. Примените схему:
```bash
wrangler d1 execute rsi-db --file=workers/schema.sql
```

5. Создайте KV namespace:
```bash
wrangler kv:namespace create "KV"
```

6. Установите секреты:
```bash
wrangler secret put FCM_SERVER_KEY
```

7. Деплой Workers:
```bash
cd workers
wrangler deploy
```

### Настройка приложения

1. **Обновите конфигурацию** в `lib/main.dart`:
```dart
// Замените на ваш Workers URL
final yahooService = YahooProtoSource('https://your-worker.workers.dev');
```

2. **Настройте Firebase** в `lib/services/firebase_service.dart`

3. **Соберите приложение**:
```bash
# iOS
flutter build ios

# Android
flutter build apk
```

## Использование

### Создание алерта
1. Откройте приложение
2. Нажмите "+" для создания алерта
3. Выберите символ (AAPL, MSFT, EURUSD=X, etc.)
4. Настройте таймфрейм и уровни RSI
5. Сохраните алерт

### Добавление виджета
1. **iOS**: Долгое нажатие на экран → "+" → RSI Widget
2. **Android**: Долгое нажатие на экран → Виджеты → RSI Widget

### Настройка уведомлений
1. Откройте Настройки в приложении
2. Включите уведомления
3. Настройте звук и вибрацию

## API

### Cloudflare Workers Endpoints

- `GET /yf/candles` - Получение свечей
- `GET /yf/quote` - Текущая цена
- `GET /yf/info` - Информация о символе
- `POST /device/register` - Регистрация устройства
- `POST /alerts/create` - Создание алерта
- `GET /alerts/:userId` - Получение алертов пользователя

### Модели данных

```dart
class AlertRule {
  String symbol;
  String timeframe;
  int rsiPeriod;
  List<double> levels;
  String mode; // cross|enter|exit
  double hysteresis;
  int cooldownSec;
  bool active;
}
```

## Разработка

### Структура проекта
```
lib/
├── main.dart                 # Точка входа
├── models.dart              # Модели данных
├── services/                # Сервисы
│   ├── rsi_service.dart     # RSI расчеты
│   ├── yahoo_proto.dart     # Yahoo Finance API
│   ├── firebase_service.dart # Firebase
│   └── notification_service.dart # Уведомления
├── screens/                 # Экраны
│   ├── home_screen.dart     # Главный экран
│   ├── alerts_screen.dart   # Управление алертами
│   └── settings_screen.dart # Настройки
└── widgets/                 # Виджеты
    └── rsi_chart.dart       # RSI график

workers/
├── src/
│   ├── index.ts            # Workers entry point
│   ├── rsi-engine.ts       # RSI движок
│   ├── fcm-service.ts      # FCM сервис
│   └── yahoo-service.ts    # Yahoo сервис
├── schema.sql              # Схема D1
└── wrangler.toml           # Конфигурация Workers
```

### Команды разработки

```bash
# Запуск в режиме разработки
flutter run

# Генерация кода
flutter packages pub run build_runner build --delete-conflicting-outputs

# Тестирование
flutter test

# Анализ кода
flutter analyze

# Сборка релиза
flutter build apk --release
flutter build ios --release
```

## Лицензия

MIT License - см. файл [LICENSE](LICENSE)

## Поддержка

- Email: support@rsiwidget.app
- GitHub Issues: [github.com/rsiwidget/issues](https://github.com/rsiwidget/issues)
- Telegram: @rsiwidget_support

## Вклад в проект

1. Форкните репозиторий
2. Создайте ветку для функции (`git checkout -b feature/amazing-feature`)
3. Зафиксируйте изменения (`git commit -m 'Add amazing feature'`)
4. Отправьте в ветку (`git push origin feature/amazing-feature`)
5. Откройте Pull Request

## Roadmap

- [ ] Поддержка больше источников данных
- [ ] Синхронизация между устройствами
- [ ] Бэктест алертов
- [ ] Темы оформления
- [ ] Экспорт/импорт настроек
- [ ] Аналитика и статистика
