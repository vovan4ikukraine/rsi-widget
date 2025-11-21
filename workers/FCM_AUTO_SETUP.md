# Автоматическая настройка FCM (без ручного обновления токенов)

Теперь FCM работает полностью автоматически! Воркер сам получает и обновляет access token из Service Account JSON.

## Настройка (один раз):

### 1. Установите Service Account JSON как секрет

```bash
cd workers
wrangler secret put FCM_SERVICE_ACCOUNT_JSON
```

Когда появится запрос, вставьте **весь содержимое** JSON файла (который вы скачали из Firebase Console).

**Важно**: Вставьте весь JSON одной строкой или используйте многострочный ввод (в зависимости от вашего терминала).

### 2. Проверьте Project ID

Убедитесь, что в `wrangler.toml` указан правильный Project ID:

```toml
[vars]
FCM_PROJECT_ID = "rsi-widget-app"  # Должен совпадать с project_id из JSON
```

### 3. Задеплойте воркер

```bash
wrangler deploy
```

## Как это работает:

1. **Автоматическое получение токена**: Воркер использует Service Account JSON для создания JWT и получения OAuth2 access token от Google
2. **Кэширование**: Токен кэшируется в KV storage и в памяти
3. **Автоматическое обновление**: Токен обновляется автоматически за 1 минуту до истечения (токены действительны 1 час)
4. **Повтор при ошибке**: Если токен истек (401 ошибка), воркер автоматически получает новый и повторяет запрос

## Больше не нужно:

- ❌ Запускать скрипт `get-fcm-token.js`
- ❌ Вручную обновлять `FCM_ACCESS_TOKEN` каждые 60 минут
- ❌ Настраивать cron jobs для обновления токена

## Проверка:

После деплоя проверьте логи:

```bash
wrangler tail
```

Вы должны увидеть:
- `Refreshing FCM access token...` - при первом использовании
- `FCM access token refreshed, expires in 3600s` - успешное получение токена
- `Using cached FCM access token` - использование кэшированного токена
- `FCM V1 message sent successfully` - успешная отправка уведомления

## Если что-то не работает:

1. Проверьте, что Service Account JSON установлен правильно:
   ```bash
   wrangler secret list
   ```

2. Проверьте логи на ошибки:
   ```bash
   wrangler tail
   ```

3. Убедитесь, что Project ID правильный в `wrangler.toml`

4. Проверьте, что Service Account имеет права на Firebase Cloud Messaging



