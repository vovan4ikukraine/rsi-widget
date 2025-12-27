# Admin Dashboard Setup

## Настройка

### 1. Установка API ключа

Установите секретный ключ для доступа к админ-панели:

```bash
cd workers
wrangler secret put ADMIN_API_KEY
```

Введите безопасный ключ (например, сгенерируйте через `openssl rand -hex 32`).

### 2. Развертывание

Админ-панель состоит из двух частей:

1. **Backend API** - уже включен в основной worker (`workers/src/index.ts`)
2. **Frontend** - статические файлы в `workers/admin/`

### 3. Размещение Frontend

Есть несколько вариантов размещения frontend:

#### Вариант A: Cloudflare Pages (рекомендуется)

1. Создайте новый Cloudflare Pages проект
2. Укажите папку `workers/admin` как корень проекта
3. Домен будет доступен по адресу `your-admin.pages.dev`

#### Вариант B: Статический хостинг

Можно разместить файлы из `workers/admin/` на любом статическом хостинге (GitHub Pages, Netlify, etc.).

#### Вариант C: Локальный сервер (для разработки)

```bash
cd workers/admin
python -m http.server 8000
# или
npx serve .
```

Затем откройте `http://localhost:8000` в браузере.

**Важно:** При использовании варианта C нужно настроить CORS на backend или использовать прокси.

### 4. Настройка API URL

По умолчанию frontend использует текущий origin как API endpoint. Если frontend размещен на другом домене, отредактируйте `workers/admin/js/api.js`:

```javascript
const API_BASE_URL = 'https://your-worker.workers.dev';
```

### 5. Использование

1. Откройте админ-панель в браузере
2. Введите API ключ (который вы установили через `wrangler secret put`)
3. Нажмите "Connect"
4. API ключ сохранится в localStorage браузера

## API Endpoints

### `GET /admin/stats`
Возвращает общую статистику:
- Пользователи (всего, активные за 24ч/7д)
- Устройства (всего, активные, по платформам)
- Алерты (всего, активные, по индикаторам)

**Требует:** заголовок `X-Admin-API-Key`

### `GET /admin/users?limit=50&offset=0`
Возвращает список пользователей с пагинацией.

**Требует:** заголовок `X-Admin-API-Key`

### `GET /admin/providers`
Возвращает текущую конфигурацию провайдеров (заглушка).

**Требует:** заголовок `X-Admin-API-Key`

### `PUT /admin/providers`
Обновляет конфигурацию провайдеров (заглушка, ничего не сохраняет).

**Требует:** заголовок `X-Admin-API-Key`

**Body:**
```json
{
  "stocks": {
    "primary": "YF_PROTO",
    "fallback": "TWELVE"
  },
  "crypto": {
    "primary": "YF_PROTO",
    "fallback": null
  },
  "forex": {
    "primary": "YF_PROTO",
    "fallback": null
  }
}
```

## Безопасность

- Все админ endpoints защищены middleware `adminAuthMiddleware`
- API ключ проверяется на каждом запросе
- В production рекомендуется ограничить CORS для админ endpoints
- Храните API ключ в секретах, не коммитьте в репозиторий

## Разработка

Для локальной разработки можно использовать:

```bash
# Terminal 1: Запустить worker локально
cd workers
wrangler dev

# Terminal 2: Запустить frontend сервер
cd workers/admin
python -m http.server 8000
```

Однако нужно будет настроить API_BASE_URL в `api.js` на `http://localhost:8787` (или другой порт wrangler).




