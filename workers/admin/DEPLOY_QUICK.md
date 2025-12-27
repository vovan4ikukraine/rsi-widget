# Быстрый деплой на Cloudflare Pages

## Вариант 1: Через Wrangler (самый быстрый)

```powershell
cd workers\admin
wrangler pages deploy . --project-name=rsi-admin-dashboard
```

Если проект еще не создан:
```powershell
wrangler pages project create rsi-admin-dashboard
```

## Вариант 2: Через веб-интерфейс Cloudflare

1. Зайдите на https://dash.cloudflare.com/
2. Pages → Create a project → Upload assets
3. Заархивируйте папку `workers/admin` в ZIP
4. Загрузите ZIP файл
5. Deploy!

## После деплоя

Вы получите URL вида: `https://rsi-admin-dashboard.pages.dev`

Откройте его, введите API ключ и используйте панель.

## Важно

Убедитесь, что в Worker (`workers/src/index.ts`) CORS настроен:
```typescript
allowHeaders: ['Content-Type', 'Authorization', 'X-Admin-API-Key'],
```

URL API уже настроен в `workers/admin/js/api.js`:
```javascript
const API_BASE_URL = 'https://rsi-workers.vovan4ikukraine.workers.dev';
```



