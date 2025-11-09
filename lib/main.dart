import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:isar/isar.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';
import 'services/notification_service.dart';
import 'services/firebase_service.dart';
import 'screens/home_screen.dart';
import 'localization/app_localizations.dart';
import 'state/app_state.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1️⃣ Initialize Firebase
  await Firebase.initializeApp();

  // 2️⃣ Get path for local database (Isar requires directory)
  final dir = await getApplicationDocumentsDirectory();

  // 3️⃣ Initialize Isar
  final isar = await Isar.open(
    [
      AlertRuleSchema,
      AlertStateSchema,
      AlertEventSchema,
      RsiDataSchema,
      DeviceInfoSchema,
      WatchlistItemSchema,
    ],
    directory: dir.path,
    name: 'rsi_alert_db',
  );

  final prefs = await SharedPreferences.getInstance();
  final languageCode = prefs.getString('language') ?? 'ru';
  final theme = prefs.getString('theme') ?? 'dark';
  final appState = AppState(
    locale: Locale(languageCode),
    themeMode: theme == 'light' ? ThemeMode.light : ThemeMode.dark,
  );

  // 4️⃣ Initialize services
  await NotificationService.initialize();
  await FirebaseService.initialize();

  // 5️⃣ Launch application
  runApp(
    AppStateScope(
      notifier: appState,
      child: RSIWidgetApp(isar: isar, appState: appState),
    ),
  );
}

class RSIWidgetApp extends StatefulWidget {
  final Isar isar;
  final AppState appState;
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  const RSIWidgetApp({
    super.key,
    required this.isar,
    required this.appState,
  });

  @override
  State<RSIWidgetApp> createState() => _RSIWidgetAppState();
}

class _RSIWidgetAppState extends State<RSIWidgetApp> {
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.appState,
      builder: (context, _) {
        return MaterialApp(
          title: 'RSI Widget',
          navigatorKey: RSIWidgetApp.navigatorKey,
          locale: widget.appState.locale,
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          themeMode: widget.appState.themeMode,
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
          ),
          darkTheme: ThemeData(
            useMaterial3: true,
            brightness: Brightness.dark,
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.blue,
              brightness: Brightness.dark,
            ),
          ),
          home: HomeScreen(isar: widget.isar),
          onGenerateRoute: (settings) {
            // Handle launch from widget for data update
            if (settings.arguments is Map &&
                (settings.arguments as Map)['update_widget'] == true) {
              // Open watchlist to update widget
              return MaterialPageRoute(
                builder: (context) => HomeScreen(isar: widget.isar),
                settings: settings,
              );
            }
            return null;
          },
          debugShowCheckedModeBanner: false,
        );
      },
    );
  }
}
