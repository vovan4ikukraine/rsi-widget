# Deployment Instructions for RSI Widget App

## Overview

This document provides step-by-step instructions for deploying the RSI Widget App, including configuring Firebase, Cloudflare Workers, and building the application.

## Prerequisites

- Flutter 3.3.0+
- Node.js 18+
- Firebase CLI
- Cloudflare account
- iOS/Android tooling installed

## 1. Configure Firebase

### 1.1 Create a Firebase project

1. Visit [Firebase Console](https://console.firebase.google.com)
2. Click **Create project**
3. Enter the project name: `rsi-widget-app`
4. Enable Google Analytics (optional)
5. Finish project creation

### 1.2 Set up authentication

1. In Firebase Console, open **Authentication**
2. Click **Get started**
3. Enable **Anonymous** authentication

### 1.3 Configure Cloud Messaging

1. Open **Cloud Messaging**
2. Click **Create your first campaign**
3. Configure notifications (can be done later)

### 1.4 Add mobile apps

#### iOS
1. Click **Add app** → iOS
2. Bundle ID: `com.example.rsi_widget`
3. Download `GoogleService-Info.plist`
4. Place it in `ios/Runner/GoogleService-Info.plist`

#### Android
1. Click **Add app** → Android
2. Package name: `com.example.rsi_widget`
3. Download `google-services.json`
4. Place it in `android/app/google-services.json`

### 1.5 Retrieve the FCM key

1. Go to **Project settings** → **General**
2. Locate the **Server keys**
3. Copy the **Server key** (required for Cloudflare Workers)

## 2. Configure Cloudflare Workers

### 2.1 Install Wrangler CLI

```bash
npm install -g wrangler
```

### 2.2 Log in

```bash
wrangler login
```

### 2.3 Create a D1 database

```bash
cd workers
wrangler d1 create rsi-db
```

Save the generated `database_id` and `database_name`.
database_name = "rsi-db"
database_id = "548f70f8-9fcb-4bca-952d-5f629c8ebd37"

### 2.4 Apply the database schema

```bash
wrangler d1 execute rsi-db --file=schema.sql
```

### 2.5 Create a KV namespace

```bash
wrangler kv:namespace create "KV"
```

Save the returned `id` and `preview_id`.
binding = "KV"
id = "537eb17689cb4cb39a13ae58dedaba57"

### 2.6 Configure `wrangler.toml`

Update `workers/wrangler.toml`:

```toml
name = "rsi-workers"
main = "src/index.ts"
compatibility_date = "2024-10-01"

[triggers]
crons = ["*/1 * * * *"]

[[kv_namespaces]]
binding = "KV"
id = "your-kv-namespace-id"
preview_id = "your-preview-kv-namespace-id"

[[d1_databases]]
binding = "DB"
database_name = "rsi-db"
database_id = "your-d1-database-id"

[vars]
ENVIRONMENT = "production"
YAHOO_ENDPOINT = "https://query1.finance.yahoo.com/v8/finance/chart"
FCM_ENDPOINT = "https://fcm.googleapis.com/fcm/send"
```

### 2.7 Add secrets

```bash
# FCM server key
wrangler secret put FCM_SERVER_KEY

# Additional secrets if needed
wrangler secret put YAHOO_API_KEY
```

### 2.8 Deploy Workers

```bash
cd workers
npm install
wrangler deploy
```

Save the deployment URL (for example: `https://rsi-workers.your-subdomain.workers.dev`)
https://rsi-workers.vovan4ikukraine.workers.dev

## 3. Configure the Flutter app

### 3.1 Update configuration

Replace the endpoint in `lib/services/yahoo_proto.dart`:

```dart
final yahooService = YahooProtoSource('https://your-worker-url.workers.dev');
```

### 3.2 Configure Firebase for Flutter

Ensure the config files are present:
- `ios/Runner/GoogleService-Info.plist`
- `android/app/google-services.json`

### 3.3 Install dependencies

```bash
flutter pub get
```

### 3.4 Generate code

```bash
flutter packages pub run build_runner build --delete-conflicting-outputs
```

## 4. Build the app

### 4.1 iOS

```bash
# Code generation
flutter packages pub run build_runner build

# iOS release build
flutter build ios --release

# Debug build for simulator
flutter build ios --debug
```

### 4.2 Android

```bash
# Build APK
flutter build apk --release

# Build App Bundle (for Google Play)
flutter build appbundle --release
```

## 5. Configure widgets

### 5.1 iOS WidgetKit

1. Open the project in Xcode: `ios/Runner.xcworkspace`
2. Add a new target: File → New → Target → Widget Extension
3. Name it `RSIWidget`
4. Copy the code from `ios/RSIWidget/RSIWidget.swift`
5. Configure the widget’s Info.plist

### 5.2 Android AppWidget

1. Ensure the widget files are present:
   - `android/app/src/main/java/com/example/rsi_widget/RSIWidgetProvider.java`
   - `android/app/src/main/res/layout/rsi_widget.xml`
   - `android/app/src/main/res/xml/rsi_widget_info.xml`

2. Update `android/app/src/main/AndroidManifest.xml`

## 6. Testing

### 6.1 Local testing

```bash
# Run in development mode
flutter run

# Test on a device
flutter run --release
```

### 6.2 Test Workers

```bash
# Run locally
cd workers
wrangler dev

# Test the API
curl https://your-worker-url.workers.dev/yf/candles?symbol=AAPL&tf=15m
```

### 6.3 Test notifications

1. Create an alert in the app
2. Confirm the data is stored in D1
3. Wait for the alert to trigger
4. Verify the push notification is delivered

## 7. Monitoring and debugging

### 7.1 Cloudflare Workers

```bash
# View logs
wrangler tail

# View metrics
wrangler analytics
```

### 7.2 Firebase

1. Open Firebase Console
2. Cloud Messaging → Statistics
3. Authentication → Users

### 7.3 Flutter

```bash
# Static analysis
flutter analyze

# Unit tests
flutter test

# Profiling
flutter run --profile
```

## 8. Production deployment

### 8.1 App Store (iOS)

1. Create an App Store Connect account
2. Create a new app
3. Upload the build via Xcode or Transporter
4. Configure metadata and screenshots
5. Submit for review

### 8.2 Google Play (Android)

1. Create a Google Play Console account
2. Create a new app
3. Upload the AAB file
4. Configure the store listing
5. Submit for review

### 8.3 Domain configuration

1. Assign a custom domain for Workers
2. Update CORS settings
3. Configure the SSL certificate

## 9. Maintenance

### 9.1 Routine tasks

- Monitor Workers logs
- Check API usage limits
- Update dependencies
- Back up the D1 database

### 9.2 Scaling

- Add additional Workers
- Optimize requests to Yahoo Finance
- Cache data in KV
- Monitor performance metrics

## 10. Security

### 10.1 Secrets

- Never commit secrets to the repository
- Use `wrangler secret put` for all keys
- Rotate keys regularly

### 10.2 CORS

- Configure the appropriate CORS headers
- Restrict access by domain
- Enforce HTTPS everywhere

### 10.3 Validation

- Validate all incoming data
- Limit request sizes
- Apply rate limiting

## Troubleshooting

### Firebase issues

```bash
# Check configuration
firebase projects:list
firebase use --add
```

### Workers issues

```bash
# Check authentication
wrangler whoami

# Reinstall dependencies
rm -rf node_modules package-lock.json
npm install
```

### Flutter issues

```bash
# Clear cache
flutter clean
flutter pub get

# Rebuild generated code
flutter packages pub run build_runner build --delete-conflicting-outputs
```

## Support

If you run into issues:

1. Review logs in the Cloudflare Dashboard
2. Check Firebase Console
3. Run `flutter doctor` for diagnostics
4. Create an issue in the GitHub repository
