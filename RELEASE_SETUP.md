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
   - ⚠️ **Временно обновлен** `google-services.json` (нужно обновить в Firebase Console)

## 🔧 Требуется ваше действие

### 1. Создание keystore для подписи релиза

Выполните следующую команду в терминале (в корне проекта):

**Для PowerShell (Windows):**
```powershell
# Вариант 1: Автоматический поиск пути
$javaHome = $env:JAVA_HOME
if (-not $javaHome) { $javaHome = "${env:ProgramFiles}\Android\Android Studio\jbr" }
& "$javaHome\bin\keytool.exe" -genkey -v -keystore android/app/upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload

# Вариант 2: Прямой путь (если первый не работает)
& "C:\Program Files\Android\Android Studio\jbr\bin\keytool.exe" -genkey -v -keystore android/app/upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

**Для CMD:**
```cmd
"C:\Program Files\Android\Android Studio\jbr\bin\keytool.exe" -genkey -v -keystore android/app/upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

**Важно:** В PowerShell обязательно используйте оператор `&` перед путем в кавычках!

**Важно:**
- Пароль keystore должен быть **минимум 6 символов**
- Вам будет предложено ввести:
  - **Keystore password** (пароль для keystore файла) - сохраните его!
  - **Key password** (пароль для ключа) - можно использовать тот же или другой
  - Ваше имя, организация и другие данные (можно заполнить или оставить пустым)

**Важно:** 
- Сохраните пароли в безопасном месте (storePassword и keyPassword)
- Сохраните alias (обычно "upload")
- Файл `upload-keystore.jks` должен быть добавлен в `.gitignore` (не коммитить!)

✅ **Настроено автоматически:** После создания keystore, конфигурация уже настроена в `android/app/build.gradle` и использует файл `android/key.properties` для безопасного хранения паролей.

**Файл `android/key.properties` создан** (уже в `.gitignore`, не будет закоммичен):
```
storePassword=TT2002TT
keyPassword=TT2002TT
keyAlias=upload
storeFile=upload-keystore.jks
```

**Важно:** Файл `key.properties` уже добавлен в `.gitignore` и не будет закоммичен в репозиторий. Это безопасный способ хранения паролей.

#### Получение SHA-1 Certificate Fingerprint

Для настройки Google Sign-In в Firebase нужны SHA-1 отпечатки сертификатов:

**1. Debug keystore (для разработки):**
```powershell
# Найти путь к keytool (обычно в Android Studio JDK)
$javaHome = $env:JAVA_HOME
if (-not $javaHome) { $javaHome = "${env:ProgramFiles}\Android\Android Studio\jbr" }

# Получить SHA-1
& "$javaHome\bin\keytool.exe" -list -v -keystore "$env:USERPROFILE\.android\debug.keystore" -alias androiddebugkey -storepass android -keypass android | Select-String -Pattern "SHA1:"
```

**Ваш текущий Debug SHA-1:** `2E:7F:94:25:9E:D0:51:31:60:51:71:25:DE:DC:25:A9:A6:D2:9F:F2`

**2. Release keystore:**
```powershell
$javaHome = "C:\Program Files\Android\Android Studio\jbr"
& "$javaHome\bin\keytool.exe" -list -v -keystore android/app/upload-keystore.jks -alias upload -storepass TT2002TT | Select-String -Pattern "SHA1:"
```

**Ваш Release SHA-1:** `DA:92:02:D5:0A:FE:B5:0B:46:35:4E:E9:DB:40:31:98:1A:7A:CC:0E`

**Примечание:** При вводе пароля в терминале символы не отображаются — это нормально для безопасности. Просто введите пароль и нажмите Enter.

**Где найти SHA-1 в выводе:**
Ищите строку вида:
```
SHA1: XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX:XX
```

**Добавление в Firebase Console:**
1. Откройте [Firebase Console](https://console.firebase.google.com/)
2. Выберите проект `rsi-widget-app` → **Project Settings** (⚙️) → вкладка **Your apps**
3. Найдите приложение с package name `com.indicharts.app`
4. Нажмите **"Add fingerprint"** (или иконку карандаша)
5. Добавьте оба SHA-1:
   - Debug: `2E:7F:94:25:9E:D0:51:31:60:51:71:25:DE:DC:25:A9:A6:D2:9F:F2`
   - Release: `DA:92:02:D5:0A:FE:B5:0B:46:35:4E:E9:DB:40:31:98:1A:7A:CC:0E`
6. Сохраните изменения
7. Скачайте обновленный `google-services.json` и замените текущий файл

### 2. Замена package name

✅ **Выполнено:** Package name заменен на `com.indicharts.app`

**⚠️ ВАЖНО:** После публикации в Google Play package name нельзя изменить!

### 3. Обновление Firebase Configuration

✅ **Выполнено:** Package name `com.indicharts.app` добавлен в Firebase Console, SHA-1 отпечатки добавлены, `google-services.json` обновлен.

⚠️ **Требуется верификация владения приложением:**

В Firebase Console отображается предупреждение о том, что владение Android клиентами не проверено. Для верификации:

1. Откройте [Firebase Console](https://console.firebase.google.com/)
2. Выберите проект `rsi-widget-app`
3. Перейдите в **Authentication** → **Settings** → **Authorized domains** (или **App Check** → **Apps**)
4. Найдите раздел **App ownership verification** или **App security**
5. Нажмите на ссылку для верификации для `com.indicharts.app`
6. Следуйте инструкциям Firebase для верификации (обычно нужно скачать файл и разместить его в приложении, или использовать SHA-256 fingerprint)

**Альтернативный способ:**
- Перейдите в **Project Settings** → **Your apps** → выберите приложение `com.indicharts.app`
- Найдите раздел **App Check** или **App ownership**
- Выполните верификацию через SHA-256 fingerprint или через размещение файла верификации

**Примечание:** Старое приложение `com.example.rsi_widget` можно удалить из Firebase Console, если оно больше не используется.

### 4. Верификация владения приложением в Firebase

⚠️ **Требуется:** В Firebase Console отображается предупреждение о том, что владение Android клиентами не проверено.

**Как верифицировать:**

1. Откройте [Firebase Console](https://console.firebase.google.com/)
2. Выберите проект `rsi-widget-app`
3. Перейдите в **Authentication** → **Settings** → вкладка **Authorized domains**
4. Или перейдите в **Project Settings** → **Your apps** → выберите приложение `com.indicharts.app`
5. Найдите раздел **App Check** или **App ownership verification**
6. Нажмите на ссылку для верификации (например, "Android client for com.indicharts.app")
7. Firebase предложит один из способов:
   - **SHA-256 fingerprint** — добавьте SHA-256 отпечаток вашего keystore
   - **Asset Links** — разместите файл `.well-known/assetlinks.json` на вашем домене
   - **Play App Signing** — если приложение уже в Google Play, используйте Play App Signing

**Получение SHA-256 для верификации:**
```powershell
$javaHome = "C:\Program Files\Android\Android Studio\jbr"
& "$javaHome\bin\keytool.exe" -list -v -keystore android/app/upload-keystore.jks -alias upload -storepass TT2002TT | Select-String -Pattern "SHA256:"
```

**Ваш Release SHA-256:** `45:91:D4:E5:65:39:4E:49:92:6A:8D:B2:6D:3B:FB:12:07:AF:95:2C:EB:4B:BF:96:62:06:E9:3B:ED:DE:ED:80`

**Для верификации:**
1. В Firebase Console нажмите на ссылку "Android client for com.indicharts.app"
2. Выберите способ верификации через SHA-256 fingerprint
3. Добавьте SHA-256: `45:91:D4:E5:65:39:4E:49:92:6A:8D:B2:6D:3B:FB:12:07:AF:95:2C:EB:4B:BF:96:62:06:E9:3B:ED:DE:ED:80`
4. Сохраните изменения

**Примечание:** Старое приложение `com.example.rsi_widget` можно удалить из Firebase Console, если оно больше не используется.

### 5. Проверка перед публикацией

- [x] Package name изменен на финальный (`com.indicharts.app`)
- [x] Keystore создан и настроен
- [x] SHA-1 добавлены в Firebase Console
- [x] `google-services.json` обновлен
- [ ] Верификация владения приложением выполнена
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
