# Admin Dashboard

Админ-панель для управления RSI Widget приложением.

## Структура

```
admin/
├── index.html          # Главная страница (Dashboard)
├── providers.html      # Страница управления провайдерами
├── css/
│   └── styles.css     # Стили
└── js/
    ├── api.js         # API клиент
    ├── dashboard.js   # Логика дашборда
    └── providers.js   # Логика провайдеров
```

## Функции

### Dashboard (index.html)
- Статистика пользователей (всего, активные за 24ч/7д)
- Статистика устройств (всего, активные, iOS/Android)
- Статистика алертов (активные, по индикаторам)
- Визуализация данных (простые графики)

### Providers (providers.html)
- Просмотр текущих настроек провайдеров
- Форма для изменения провайдеров (заглушка)
- Статус провайдеров (online/offline)

## Быстрый старт

1. Установите ADMIN_API_KEY:
   ```bash
   cd workers
   wrangler secret put ADMIN_API_KEY
   ```

2. Разместите файлы из `workers/admin/` на статическом хостинге:
   - Cloudflare Pages (рекомендуется)
   - GitHub Pages
   - Любой другой статический хостинг

3. Откройте админ-панель в браузере и введите API ключ

## API Endpoints

Все endpoints требуют заголовок `X-Admin-API-Key`.

- `GET /admin/stats` - Общая статистика
- `GET /admin/users` - Список пользователей
- `GET /admin/providers` - Текущие настройки провайдеров
- `PUT /admin/providers` - Обновить провайдеры (заглушка)

Подробнее: см. `ADMIN_SETUP.md` в корне `workers/`.




