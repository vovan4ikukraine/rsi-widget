# Инструкции по развертыванию RSI Widget App

## Обзор

Этот документ содержит пошаговые инструкции по развертыванию RSI Widget App, включая настройку Firebase, Cloudflare Workers и сборку приложения.

## Предварительные требования

- Flutter 3.3.0+
- Node.js 18+
- Firebase CLI
- Cloudflare аккаунт
- iOS/Android разработка настроена

## 1. Настройка Firebase

### 1.1 Создание проекта Firebase

1. Перейдите в [Firebase Console](https://console.firebase.google.com)
2. Нажмите "Создать проект"
3. Введите название: `rsi-widget-app`
4. Включите Google Analytics (опционально)
5. Создайте проект

### 1.2 Настройка аутентификации

1. В консоли Firebase перейдите в "Authentication"
2. Нажмите "Начать"
3. Включите "Анонимная" аутентификация

### 1.3 Настройка Cloud Messaging

1. Перейдите в "Cloud Messaging"
2. Нажмите "Создать первую кампанию"
3. Настройте уведомления (позже)

### 1.4 Добавление приложений

#### iOS
1. Нажмите "Добавить приложение" → iOS
2. Введите Bundle ID: `com.example.rsi_widget`
3. Скачайте `GoogleService-Info.plist`
4. Поместите в `ios/Runner/GoogleService-Info.plist`

#### Android
1. Нажмите "Добавить приложение" → Android
2. Введите Package name: `com.example.rsi_widget`
3. Скачайте `google-services.json`
4. Поместите в `android/app/google-services.json`

### 1.5 Получение FCM ключа

1. Перейдите в "Настройки проекта" → "Общие"
2. Найдите "Серверные ключи"
3. Скопируйте "Ключ сервера" (будет нужен для Cloudflare Workers)

## 2. Настройка Cloudflare Workers

### 2.1 Установка Wrangler CLI

```bash
npm install -g wrangler
```

### 2.2 Вход в аккаунт

```bash
wrangler login
```

### 2.3 Создание D1 базы данных

```bash
cd workers
wrangler d1 create rsi-db
```

Сохраните полученный `database_id` и `database_name`.
database_name = "rsi-db"
database_id = "548f70f8-9fcb-4bca-952d-5f629c8ebd37"

### 2.4 Применение схемы базы данных

```bash
wrangler d1 execute rsi-db --file=schema.sql
```

### 2.5 Создание KV namespace

```bash
wrangler kv:namespace create "KV"
```

Сохраните полученные `id` и `preview_id`.
binding = "KV"
id = "537eb17689cb4cb39a13ae58dedaba57"

### 2.6 Настройка wrangler.toml

Обновите `workers/wrangler.toml`:

```toml
name = "rsi-workers"
main = "src/index.ts"
compatibility_date = "2024-10-01"

[triggers]
crons = ["*/1 * * * *"]

[[kv_namespaces]]
binding = "KV"
id = "your-kv-namespace-id"
preview_id = "your-preview-kv-namespace-id"

[[d1_databases]]
binding = "DB"
database_name = "rsi-db"
database_id = "your-d1-database-id"

[vars]
ENVIRONMENT = "production"
YAHOO_ENDPOINT = "https://query1.finance.yahoo.com/v8/finance/chart"
FCM_ENDPOINT = "https://fcm.googleapis.com/fcm/send"
```

### 2.7 Установка секретов

```bash
# FCM ключ сервера
wrangler secret put FCM_SERVER_KEY

# Другие секреты при необходимости
wrangler secret put YAHOO_API_KEY
```

### 2.8 Деплой Workers

```bash
cd workers
npm install
wrangler deploy
```

Сохраните полученный URL (например: `https://rsi-workers.your-subdomain.workers.dev`)
https://rsi-workers.vovan4ikukraine.workers.dev

## 3. Настройка Flutter приложения

### 3.1 Обновление конфигурации

В `lib/services/yahoo_proto.dart` замените URL:

```dart
final yahooService = YahooProtoSource('https://your-worker-url.workers.dev');
```

### 3.2 Настройка Firebase в Flutter

Убедитесь, что файлы конфигурации на месте:
- `ios/Runner/GoogleService-Info.plist`
- `android/app/google-services.json`

### 3.3 Установка зависимостей

```bash
flutter pub get
```

### 3.4 Генерация кода

```bash
flutter packages pub run build_runner build --delete-conflicting-outputs
```

## 4. Сборка приложения

### 4.1 iOS

```bash
# Генерация кода
flutter packages pub run build_runner build

# Сборка для iOS
flutter build ios --release

# Или для симулятора
flutter build ios --debug
```

### 4.2 Android

```bash
# Сборка APK
flutter build apk --release

# Сборка App Bundle (для Google Play)
flutter build appbundle --release
```

## 5. Настройка виджетов

### 5.1 iOS WidgetKit

1. Откройте проект в Xcode: `ios/Runner.xcworkspace`
2. Добавьте новый Target: File → New → Target → Widget Extension
3. Название: `RSIWidget`
4. Скопируйте код из `ios/RSIWidget/RSIWidget.swift`
5. Настройте Info.plist для виджета

### 5.2 Android AppWidget

1. Убедитесь, что файлы виджета на месте:
   - `android/app/src/main/java/com/example/rsi_widget/RSIWidgetProvider.java`
   - `android/app/src/main/res/layout/rsi_widget.xml`
   - `android/app/src/main/res/xml/rsi_widget_info.xml`

2. Обновите `android/app/src/main/AndroidManifest.xml`

## 6. Тестирование

### 6.1 Локальное тестирование

```bash
# Запуск в режиме разработки
flutter run

# Тестирование на устройстве
flutter run --release
```

### 6.2 Тестирование Workers

```bash
# Локальный запуск
cd workers
wrangler dev

# Тестирование API
curl https://your-worker-url.workers.dev/yf/candles?symbol=AAPL&tf=15m
```

### 6.3 Тестирование уведомлений

1. Создайте алерт в приложении
2. Проверьте, что данные сохраняются в D1
3. Дождитесь срабатывания алерта
4. Проверьте получение push уведомления

## 7. Мониторинг и отладка

### 7.1 Cloudflare Workers

```bash
# Просмотр логов
wrangler tail

# Просмотр метрик
wrangler analytics
```

### 7.2 Firebase

1. Перейдите в Firebase Console
2. Cloud Messaging → Статистика
3. Authentication → Пользователи

### 7.3 Flutter

```bash
# Анализ кода
flutter analyze

# Тестирование
flutter test

# Профилирование
flutter run --profile
```

## 8. Производственное развертывание

### 8.1 App Store (iOS)

1. Создайте App Store Connect аккаунт
2. Создайте новое приложение
3. Загрузите билд через Xcode или Application Loader
4. Настройте метаданные и скриншоты
5. Отправьте на ревью

### 8.2 Google Play (Android)

1. Создайте Google Play Console аккаунт
2. Создайте новое приложение
3. Загрузите AAB файл
4. Настройте магазин
5. Отправьте на ревью

### 8.3 Настройка домена

1. Настройте кастомный домен для Workers
2. Обновите CORS настройки
3. Настройте SSL сертификат

## 9. Обслуживание

### 9.1 Регулярные задачи

- Мониторинг логов Workers
- Проверка лимитов API
- Обновление зависимостей
- Резервное копирование D1

### 9.2 Масштабирование

- Настройка дополнительных Workers
- Оптимизация запросов к Yahoo Finance
- Кэширование данных в KV
- Мониторинг производительности

## 10. Безопасность

### 10.1 Секреты

- Никогда не коммитьте секреты в репозиторий
- Используйте `wrangler secret put` для всех ключей
- Регулярно ротируйте ключи

### 10.2 CORS

- Настройте правильные CORS заголовки
- Ограничьте доступ по доменам
- Используйте HTTPS везде

### 10.3 Валидация

- Валидируйте все входящие данные
- Ограничьте размер запросов
- Используйте rate limiting

## Устранение неполадок

### Проблемы с Firebase

```bash
# Проверка конфигурации
firebase projects:list
firebase use --add
```

### Проблемы с Workers

```bash
# Проверка статуса
wrangler whoami

# Переустановка зависимостей
rm -rf node_modules package-lock.json
npm install
```

### Проблемы с Flutter

```bash
# Очистка кэша
flutter clean
flutter pub get

# Пересборка
flutter packages pub run build_runner build --delete-conflicting-outputs
```

## Поддержка

При возникновении проблем:

1. Проверьте логи в Cloudflare Dashboard
2. Проверьте Firebase Console
3. Используйте `flutter doctor` для диагностики
4. Создайте issue в GitHub репозитории
