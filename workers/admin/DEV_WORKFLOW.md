# Workflow разработки Admin Dashboard

## Локальная разработка

### Вариант 1: Простой HTTP сервер (как сейчас)

```powershell
cd workers\admin
python -m http.server 8000
```

Откройте http://localhost:8000

### Вариант 2: Wrangler Pages Dev (рекомендуется)

```powershell
cd workers\admin
wrangler pages dev .
```

Откроется локальный сервер (обычно http://localhost:8788)

**Преимущества:**
- Более точно имитирует Cloudflare Pages окружение
- Автоматическая перезагрузка при изменениях

## Деплой изменений

### После внесения изменений:

```powershell
cd workers\admin
wrangler pages deploy . --project-name=rsi-admin-dashboard
```

**Это все!** Не нужно архивировать или загружать ZIP файлы.

## Автоматический деплой через GitHub (опционально)

Если хотите автоматический деплой:

1. В Cloudflare Dashboard → Pages → ваш проект
2. Settings → Builds & deployments
3. Настройте:
   - **Production branch**: `main` (или другая)
   - **Build command**: (оставить пустым)
   - **Build output directory**: `workers/admin`
   - **Root directory**: `/workers/admin` или установите относительно корня репозитория

4. При каждом пуше в основную ветку проект будет автоматически деплоиться

## Типичный workflow

```powershell
# 1. Внесите изменения в файлы
# (редактируйте HTML, CSS, JS файлы)

# 2. Проверьте локально (опционально)
cd workers\admin
python -m http.server 8000

# 3. Задеплойте
wrangler pages deploy . --project-name=rsi-admin-dashboard

# Готово! Изменения уже на production
```

## Hot Reload для разработки

Можно использовать любой простой HTTP сервер с авто-перезагрузкой:

```powershell
# Установить (один раз)
npm install -g live-server

# Использовать
cd workers\admin
live-server
```

Или использовать встроенные возможности вашего редактора (VS Code Live Server extension и т.д.)



