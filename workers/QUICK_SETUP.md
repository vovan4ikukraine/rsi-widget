# 🚀 Быстрая настройка Admin Dashboard

## 1️⃣ Установить API ключ

```powershell
cd workers
wrangler secret put ADMIN_API_KEY
```

Введите ключ (можно любой, например: `my-admin-key-12345`)

## 2️⃣ Развернуть Backend

```powershell
wrangler deploy
```

## 3️⃣ Запустить Frontend (локально)

```powershell
cd admin
python -m http.server 8000
```

Или:
```powershell
npx serve .
```

## 4️⃣ Открыть в браузере

1. Откройте: `http://localhost:8000`
2. Введите API ключ (из шага 1)
3. Нажмите "Connect"
4. Готово! 🎉

---

**Для production:** Используйте Cloudflare Pages (см. `SETUP_ADMIN_STEPS.md`)




