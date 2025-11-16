# Настройка FCM V1 API для Cloudflare Workers

Firebase Cloud Messaging Legacy API отключен. Теперь нужно использовать FCM HTTP V1 API.

## Шаги настройки:

### 1. Получите Service Account JSON

1. Откройте [Firebase Console](https://console.firebase.google.com/)
2. Выберите ваш проект
3. Перейдите в **Project Settings** → **Service Accounts**
4. Нажмите **Generate New Private Key**
5. Сохраните JSON файл (например, `service-account.json`)

### 2. Установите зависимости для скрипта

```bash
cd workers
npm install
```

### 3. Получите Access Token

Запустите скрипт для получения OAuth2 access token:

```bash
node scripts/get-fcm-token.js path/to/service-account.json
```

Скрипт выведет access token. **Важно**: Access token действителен только 1 час!

### 4. Установите секреты в Cloudflare Workers

```bash
# Установите access token (будет действителен 1 час)
wrangler secret put FCM_ACCESS_TOKEN
# Вставьте access token из шага 3
```

### 5. Обновите wrangler.toml

Откройте `workers/wrangler.toml` и замените `your-firebase-project-id` на ваш Project ID:

```toml
[vars]
FCM_PROJECT_ID = "your-actual-project-id"  # Найти в Firebase Console → Project Settings → General
```

Project ID можно найти в Firebase Console:
- **Project Settings** → **General** → **Project ID**

### 6. Задеплойте воркер

```bash
wrangler deploy
```

## Автоматическое обновление токена

Access token истекает через 1 час. Для автоматического обновления:

1. Настройте cron job на вашем сервере, который будет:
   - Запускать `node scripts/get-fcm-token.js` каждый час
   - Обновлять секрет через `wrangler secret put FCM_ACCESS_TOKEN`

2. Или используйте Cloudflare Workers Scheduled Events для автоматического обновления токена

## Альтернатива: Использование Service Account напрямую

Если вы хотите избежать ручного обновления токена, можно:
1. Хранить Service Account JSON как секрет
2. Реализовать автоматическое получение токена в самом воркере (требует библиотеку для JWT)

Но это сложнее и требует дополнительных зависимостей.

## Проверка

После настройки проверьте логи:

```bash
wrangler tail
```

Если все настроено правильно, вы увидите:
```
FCM V1 message sent successfully to ...
```

Если есть ошибки, проверьте:
- Правильность Project ID
- Действительность access token (не истек ли)
- Правильность FCM token в базе данных


