# Admin Dashboard Plan

## Архитектура

### Backend (Cloudflare Workers)
- **Роуты:** `/admin/*` - защищенные админ-эндпоинты
- **Аутентификация:** Простой API key через env переменную `ADMIN_API_KEY`
- **База данных:** D1 (SQLite) - существующая БД

### Frontend
- **Технология:** Vanilla HTML/CSS/JavaScript (простота, без сборки)
- **Размещение:** Статические файлы в `workers/admin/` или отдельный Cloudflare Pages
- **Стили:** Material Design Components (MDC) или простой CSS

## Структура файлов

```
workers/
├── src/
│   ├── admin/
│   │   ├── auth.ts          # Middleware для аутентификации
│   │   ├── stats.ts         # Логика статистики
│   │   └── providers.ts     # Логика провайдеров (заглушка)
│   └── index.ts             # Добавить /admin/* роуты
├── admin/                   # Статические файлы админки
│   ├── index.html
│   ├── dashboard.html
│   ├── providers.html
│   ├── css/
│   │   └── styles.css
│   └── js/
│       ├── api.js           # API клиент
│       ├── dashboard.js     # Логика дашборда
│       └── providers.js     # Логика провайдеров
└── wrangler.toml            # Добавить ADMIN_API_KEY в секреты
```

## API Endpoints

### Статистика
- `GET /admin/stats` - Общая статистика
  ```json
  {
    "users": {
      "total": 1234,
      "active24h": 567,
      "active7d": 890,
      "authenticated": 456,
      "anonymous": 778
    },
    "devices": {
      "total": 2345,
      "active": 1234,
      "ios": 1000,
      "android": 1345
    },
    "alerts": {
      "total": 5678,
      "active": 3456,
      "byIndicator": {
        "rsi": 2000,
        "stoch": 1000,
        "williams": 456
      }
    }
  }
  ```

- `GET /admin/users?limit=50&offset=0` - Список пользователей
- `GET /admin/alerts/stats` - Статистика по алертам

### Провайдеры (заглушка)
- `GET /admin/providers` - Получить текущие настройки провайдеров
  ```json
  {
    "stocks": {
      "primary": "YF_PROTO",
      "fallback": null,
      "status": "online"
    },
    "crypto": {
      "primary": "YF_PROTO",
      "fallback": null,
      "status": "online"
    },
    "forex": {
      "primary": "YF_PROTO",
      "fallback": null,
      "status": "online"
    }
  }
  ```

- `PUT /admin/providers` - Обновить провайдеры (заглушка, ничего не делает)
  ```json
  {
    "stocks": {
      "primary": "YF_PROTO",
      "fallback": "TWELVE"
    }
  }
  ```

## Интерфейс

### Главная страница (Dashboard)
1. **Карточки метрик:**
   - Всего пользователей
   - Активных за 24ч
   - Всего устройств
   - Активных алертов

2. **Графики:**
   - Рост пользователей (линейный график, последние 30 дней)
   - Распределение по платформам (pie chart)
   - Распределение алертов по индикаторам (bar chart)

3. **Таблицы:**
   - Топ-10 популярных символов
   - Последние активные пользователи

### Страница провайдеров
1. **Текущие настройки:**
   - Stocks: Primary / Fallback / Status
   - Crypto: Primary / Fallback / Status
   - Forex: Primary / Fallback / Status

2. **Форма изменения:**
   - Dropdown для выбора Primary провайдера
   - Dropdown для выбора Fallback провайдера
   - Кнопка "Сохранить" (заглушка, показывает alert)

3. **Статус:**
   - Онлайн/Оффлайн индикатор
   - Последний успешный запрос
   - Количество ошибок

## Безопасность

1. **API Key Authentication:**
   - Все запросы к `/admin/*` требуют заголовок `X-Admin-API-Key`
   - Middleware проверяет ключ перед обработкой

2. **CORS:**
   - Разрешить только с домена админки (опционально)

3. **Rate Limiting:**
   - Ограничить количество запросов (опционально)

## Реализация (MVP)

### Фаза 1: Backend API
- [ ] Middleware аутентификации
- [ ] Endpoint `/admin/stats`
- [ ] Endpoint `/admin/providers` (GET/PUT заглушки)

### Фаза 2: Frontend
- [ ] HTML структура дашборда
- [ ] CSS стилизация
- [ ] JavaScript для загрузки статистики
- [ ] Страница провайдеров с формой (заглушка)

### Фаза 3: Полировка
- [ ] Графики (Chart.js или простые SVG)
- [ ] Обработка ошибок
- [ ] Loading states
- [ ] Responsive дизайн




