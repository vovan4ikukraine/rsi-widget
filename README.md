# RSI Widget App

Mobile application for RSI alerts and widgets on iOS and Android.

## Description

RSI Widget App is a cross-platform mobile application that:
- Shows RSI chart for selected instrument (stocks, crypto, FX)
- Sends notifications when RSI crosses specified levels
- Works autonomously as a widget on phone screen
- Supports iOS and Android with unified codebase

## Features

### Main Capabilities
- **RSI Chart**: Display RSI with configurable levels (30/70, 20/80, custom)
- **Alerts**: Notifications on RSI level crossings with hysteresis
- **Widgets**: iOS WidgetKit and Android AppWidget with mini-charts
- **Multiple Instruments**: Stocks, forex, cryptocurrencies
- **Timeframes**: 1m, 5m, 15m, 1h, 4h, 1d

### Technical Features
- **Cross-platform**: Flutter for iOS and Android
- **Local Database**: Isar for data caching
- **Push Notifications**: Firebase Cloud Messaging
- **Backend**: Cloudflare Workers with D1 database
- **Data Sources**: Yahoo Finance (free)

## Architecture

### Client (Flutter)
- **UI**: Material Design with dark theme
- **Charts**: fl_chart for RSI display
- **Database**: Isar for local storage
- **Notifications**: flutter_local_notifications + Firebase

### Backend (Cloudflare Workers)
- **Cron Jobs**: Alert checks every minute
- **RSI Engine**: RSI calculation using Wilder's algorithm
- **FCM**: Push notification sending
- **Database**: D1 (SQLite) for rule storage

### Widgets
- **iOS**: WidgetKit with SwiftUI
- **Android**: AppWidget with RemoteViews

## Installation

### Requirements
- Flutter 3.3.0+
- Dart 3.0+
- iOS 12.0+ / Android API 21+
- Firebase project
- Cloudflare Workers account

### Project Setup

1. **Clone repository**
```bash
git clone https://github.com/your-repo/rsi-widget.git
cd rsi-widget
```

2. **Install dependencies**
```bash
flutter pub get
```

3. **Code generation**
```bash
flutter packages pub run build_runner build
```

### Firebase Setup

1. Create project in [Firebase Console](https://console.firebase.google.com)
2. Add iOS and Android apps
3. Download configuration files:
   - `ios/Runner/GoogleService-Info.plist`
   - `android/app/google-services.json`
4. Enable Cloud Messaging in Firebase console

### Cloudflare Workers Setup

1. Install Wrangler CLI:
```bash
npm install -g wrangler
```

2. Login to account:
```bash
wrangler login
```

3. Create D1 database:
```bash
wrangler d1 create rsi-db
```

4. Apply schema:
```bash
wrangler d1 execute rsi-db --file=workers/schema.sql
```

5. Create KV namespace:
```bash
wrangler kv:namespace create "KV"
```

6. Set secrets:
```bash
wrangler secret put FCM_SERVER_KEY
```

7. Deploy Workers:
```bash
cd workers
wrangler deploy
```

### App Configuration

1. **Update configuration** in `lib/main.dart`:
```dart
// Replace with your Workers URL
final yahooService = YahooProtoSource('https://your-worker.workers.dev');
```

2. **Configure Firebase** in `lib/services/firebase_service.dart`

3. **Build application**:
```bash
# iOS
flutter build ios

# Android
flutter build apk
```

## Usage

### Creating Alert
1. Open application
2. Tap "+" to create alert
3. Select symbol (AAPL, MSFT, EURUSD=X, etc.)
4. Configure timeframe and RSI levels
5. Save alert

### Adding Widget
1. **iOS**: Long press on screen → "+" → RSI Widget
2. **Android**: Long press on screen → Widgets → RSI Widget

### Notification Settings
1. Open Settings in app
2. Enable notifications
3. Configure sound and vibration

## API

### Cloudflare Workers Endpoints

- `GET /yf/candles` - Get candles
- `GET /yf/quote` - Current price
- `GET /yf/info` - Symbol information
- `POST /device/register` - Device registration
- `POST /alerts/create` - Create alert
- `GET /alerts/:userId` - Get user alerts

### Data Models

```dart
class AlertRule {
  String symbol;
  String timeframe;
  int rsiPeriod;
  List<double> levels;
  String mode; // cross|enter|exit
  double hysteresis;
  int cooldownSec;
  bool active;
}
```

## Development

### Project Structure
```
lib/
├── main.dart                 # Entry point
├── models.dart              # Data models
├── services/                # Services
│   ├── rsi_service.dart     # RSI calculations
│   ├── yahoo_proto.dart     # Yahoo Finance API
│   ├── firebase_service.dart # Firebase
│   └── notification_service.dart # Notifications
├── screens/                 # Screens
│   ├── home_screen.dart     # Main screen
│   ├── alerts_screen.dart   # Alert management
│   └── settings_screen.dart # Settings
└── widgets/                 # Widgets
    └── rsi_chart.dart       # RSI chart

workers/
├── src/
│   ├── index.ts            # Workers entry point
│   ├── rsi-engine.ts       # RSI engine
│   ├── fcm-service.ts      # FCM service
│   └── yahoo-service.ts    # Yahoo service
├── schema.sql              # D1 schema
└── wrangler.toml           # Workers configuration
```

### Development Commands

```bash
# Run in development mode
flutter run

# Code generation
flutter packages pub run build_runner build --delete-conflicting-outputs

# Testing
flutter test

# Code analysis
flutter analyze

# Release build
flutter build apk --release
flutter build ios --release
```

## License

MIT License - see [LICENSE](LICENSE) file

## Support

- Email: support@rsiwidget.app
- GitHub Issues: [github.com/rsiwidget/issues](https://github.com/rsiwidget/issues)
- Telegram: @rsiwidget_support

## Contributing

1. Fork the repository
2. Create feature branch (`git checkout -b feature/amazing-feature`)
3. Commit changes (`git commit -m 'Add amazing feature'`)
4. Push to branch (`git push origin feature/amazing-feature`)
5. Open Pull Request

## Roadmap

- [ ] Support for more data sources
- [ ] Sync between devices
- [ ] Alert backtesting
- [ ] Theme customization
- [ ] Settings export/import
- [ ] Analytics and statistics
