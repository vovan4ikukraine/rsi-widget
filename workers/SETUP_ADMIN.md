# Быстрая настройка Admin Dashboard

## Шаг 1: Установка ADMIN_API_KEY

Выполните команду для установки секретного ключа:

```bash
cd workers
wrangler secret put ADMIN_API_KEY
```

Когда появится запрос, введите безопасный ключ. Например, можете сгенерировать его:

**На Windows (PowerShell):**
```powershell
-join ((65..90) + (97..122) + (48..57) | Get-Random -Count 32 | ForEach-Object {[char]$_})
```

**Или используйте любой длинный случайный ключ, например:**
```
my-super-secret-admin-key-2024-change-this-in-production
```

## Шаг 2: Развертывание Backend

Backend уже включен в ваш worker. Просто разверните изменения:

```bash
cd workers
wrangler deploy
```

## Шаг 3: Настройка Frontend

Есть два варианта:

### Вариант A: Локальный запуск (для тестирования)

1. Запустите локальный сервер в папке admin:
```bash
cd workers/admin
python -m http.server 8000
# или если нет Python:
# npx serve .
```

2. Откройте браузер: `http://localhost:8000`

3. Нужно настроить API URL. Отредактируйте `workers/admin/js/api.js`:
   - Найдите строку с `API_BASE_URL`
   - Замените на URL вашего worker (например: `https://rsi-workers.vovan4ikukraine.workers.dev`)

### Вариант B: Cloudflare Pages (рекомендуется для production)

1. Перейдите в Cloudflare Dashboard → Pages
2. Create a project
3. Выберите "Upload assets"
4. Загрузите папку `workers/admin/`
5. Deploy

## Шаг 4: Использование

1. Откройте админ-панель
2. Введите API ключ (который вы установили в шаге 1)
3. Нажмите "Connect"
4. Готово! Вы увидите статистику




