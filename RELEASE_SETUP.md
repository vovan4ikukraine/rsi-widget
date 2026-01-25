# Инструкция по настройке релиза

## ✅ Выполнено автоматически

1. ✅ **Target SDK** изменен с 36 на 35
2. ✅ **ProGuard/R8** включен (minifyEnabled, shrinkResources)
3. ✅ **Структура signingConfigs.release** подготовлена
4. ✅ **proguard-rules.pro** создан
5. ✅ **Package name** заменен на `com.indicharts.app` во всех файлах
   - Обновлен `android/app/build.gradle` (applicationId и namespace)
   - Обновлен `android/app/src/main/AndroidManifest.xml` (package и intent-filter actions)
   - Перемещены Kotlin файлы в `com/indicharts/app/`
   - Обновлены package declarations во всех Kotlin файлах
   - Обновлен MethodChannel в MainActivity.kt
   - Обновлен proguard-rules.pro

## 🔧 Требуется ваше действие

### 1. Создание keystore для подписи релиза

Выполните следующую команду в терминале (в корне проекта):

```bash
keytool -genkey -v -keystore android/app/upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

**Важно:** 
- Сохраните пароли в безопасном месте (storePassword и keyPassword)
- Сохраните alias (обычно "upload")
- Файл `upload-keystore.jks` должен быть добавлен в `.gitignore` (не коммитить!)

После создания keystore, обновите `android/app/build.gradle`:

```gradle
signingConfigs {
    release {
        storeFile file('upload-keystore.jks')
        storePassword System.getenv("KEYSTORE_PASSWORD") ?: 'your-store-password'
        keyAlias System.getenv("KEY_ALIAS") ?: 'upload'
        keyPassword System.getenv("KEY_PASSWORD") ?: 'your-key-password'
    }
}
```

**Рекомендация:** Используйте переменные окружения для паролей вместо хардкода.

### 2. Замена package name

✅ **Выполнено:** Package name заменен на `com.indicharts.app`

**⚠️ ВАЖНО:** После публикации в Google Play package name нельзя изменить!

### 3. Проверка перед публикацией

- [x] Package name изменен на финальный (`com.indicharts.app`)
- [ ] Keystore создан и настроен
- [ ] Все тесты пройдены
- [ ] Release сборка успешна: `flutter build appbundle --release`
- [ ] APK/AAB протестирован на реальном устройстве

## 📦 Сборка для публикации

После настройки keystore и package name:

```bash
# App Bundle (рекомендуется для Google Play)
flutter build appbundle --release

# Или APK (если нужен)
flutter build apk --release
```

Файл будет в: `build/app/outputs/bundle/release/app-release.aab`
