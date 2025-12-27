# Деплой Admin Dashboard на Cloudflare Pages

## Способ 1: Через Wrangler CLI (Быстрый)

### Шаг 1: Установка Wrangler (если еще не установлен)

```bash
npm install -g wrangler
```

### Шаг 2: Логин в Cloudflare

```bash
wrangler login
```

### Шаг 3: Создание проекта Pages

```bash
cd workers/admin
wrangler pages project create rsi-admin-dashboard
```

### Шаг 4: Деплой файлов

```bash
wrangler pages deploy . --project-name=rsi-admin-dashboard
```

После успешного деплоя вы получите URL вида: `https://rsi-admin-dashboard.pages.dev`

---

## Способ 2: Через GitHub (Рекомендуется - автоматический деплой)

### Шаг 1: Подготовка репозитория

1. Убедитесь, что все файлы админ-панели находятся в `workers/admin/`
2. Закоммитьте и запушьте изменения в GitHub

### Шаг 2: Создание проекта в Cloudflare Pages

1. Зайдите в [Cloudflare Dashboard](https://dash.cloudflare.com/)
2. Выберите **Pages** в боковом меню
3. Нажмите **Create a project**
4. Выберите **Connect to Git**
5. Авторизуйтесь через GitHub и выберите ваш репозиторий

### Шаг 3: Настройка проекта

**Build settings:**
- **Framework preset**: None (или Static HTML)
- **Build command**: (оставить пустым, так как это статические файлы)
- **Build output directory**: `workers/admin`
- **Root directory**: (оставить пустым или установить `/workers/admin`)

**Environment variables:** (не требуется для статических файлов)

### Шаг 4: Деплой

1. Нажмите **Save and Deploy**
2. Cloudflare автоматически задеплоит ваш проект
3. После успешного деплоя вы получите URL вида: `https://your-project-name.pages.dev`

### Шаг 5: Настройка кастомного домена (опционально)

1. В настройках проекта перейдите в **Custom domains**
2. Нажмите **Set up a custom domain**
3. Введите ваш домен (например: `admin.yourdomain.com`)
4. Следуйте инструкциям по настройке DNS записей

---

## Способ 3: Через Cloudflare Dashboard (Drag & Drop)

1. Зайдите в [Cloudflare Dashboard](https://dash.cloudflare.com/)
2. Выберите **Pages** → **Create a project**
3. Выберите **Upload assets**
4. Создайте ZIP архив папки `workers/admin` (включая все файлы: index.html, providers.html, css/, js/)
5. Загрузите ZIP файл
6. Нажмите **Deploy site**

---

## Важные примечания

### CORS

Убедитесь, что в вашем Worker (`workers/src/index.ts`) CORS настроен правильно и включает заголовок `X-Admin-API-Key`:

```typescript
app.use('*', cors({
    origin: '*',
    allowHeaders: ['Content-Type', 'Authorization', 'X-Admin-API-Key'],
    allowMethods: ['GET', 'POST', 'PUT', 'DELETE', 'OPTIONS'],
}));
```

### API URL

Файл `workers/admin/js/api.js` уже настроен на использование вашего Worker URL:
```javascript
const API_BASE_URL = 'https://rsi-workers.vovan4ikukraine.workers.dev';
```

Если вы изменили URL Worker, обновите этот файл перед деплоем.

### Безопасность

- API ключ хранится в `localStorage` браузера
- Рекомендуется использовать HTTPS (Cloudflare Pages автоматически предоставляет)
- Для дополнительной безопасности можно ограничить доступ по IP в Cloudflare

---

## Проверка деплоя

После деплоя:

1. Откройте URL вашего проекта
2. Введите Admin API Key
3. Проверьте, что Dashboard загружается без ошибок
4. Проверьте консоль браузера (F12) на наличие ошибок

---

## Обновление

### Если используете Wrangler CLI:
```bash
cd workers/admin
wrangler pages deploy . --project-name=rsi-admin-dashboard
```

### Если используете GitHub:
Просто запушьте изменения в репозиторий - Cloudflare автоматически задеплоит обновления.

---

## Troubleshooting

### "Failed to fetch" ошибка

1. Проверьте, что Worker развернут и доступен
2. Проверьте CORS настройки в Worker
3. Проверьте консоль браузера на наличие CORS ошибок
4. Убедитесь, что API URL правильный в `api.js`

### Страницы не найдены (404)

Если у вас есть несколько HTML страниц, создайте файл `_redirects` в папке `workers/admin/`:
```
/providers.html  /providers.html  200
```

Или используйте Cloudflare Pages Functions для более сложной маршрутизации.



