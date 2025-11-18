import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:isar/isar.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';
import 'services/notification_service.dart';
import 'services/firebase_service.dart';
import 'services/user_service.dart';
import 'services/auth_service.dart';
import 'services/alert_sync_service.dart';
import 'services/data_sync_service.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'localization/app_localizations.dart';
import 'state/app_state.dart';
import 'package:flutter/foundation.dart';

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
  await UserService.initialize();

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
          home: _AuthWrapper(isar: widget.isar),
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.blue,
              brightness: Brightness.light,
            ),
            scaffoldBackgroundColor: const Color(0xFFF4F6FB),
            cardTheme: CardThemeData(
              color: Colors.white,
              elevation: 6,
              shadowColor: Colors.black.withValues(alpha: 0.08),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              margin: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
            ),
            inputDecorationTheme: InputDecorationTheme(
              filled: true,
              fillColor: const Color(0xFFFCFDFF),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: Color(0xFFD8DEEB)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: Color(0xFFD8DEEB)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(
                    color: Colors.blue.withValues(alpha: 0.5), width: 1.6),
              ),
            ),
            dropdownMenuTheme: DropdownMenuThemeData(
              textStyle: TextStyle(
                color: Colors.blueGrey[900],
                fontSize: 14,
              ),
            ),
            appBarTheme: const AppBarTheme(
              backgroundColor: Colors.transparent,
              foregroundColor: Colors.black87,
              elevation: 0,
            ),
          ),
          darkTheme: ThemeData(
            useMaterial3: true,
            brightness: Brightness.dark,
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.blue,
              brightness: Brightness.dark,
            ),
            scaffoldBackgroundColor: const Color(0xFF11141C),
            cardTheme: CardThemeData(
              color: const Color(0xFF1C212C),
              elevation: 4,
              shadowColor: Colors.black.withValues(alpha: 0.2),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              margin: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
            ),
            inputDecorationTheme: InputDecorationTheme(
              filled: true,
              fillColor: const Color(0xFF181C26),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: Color(0xFF2C3342)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: Color(0xFF2C3342)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(
                    color: Colors.blue.withValues(alpha: 0.5), width: 1.5),
              ),
            ),
            dropdownMenuTheme: const DropdownMenuThemeData(
              textStyle: TextStyle(
                color: Colors.white,
                fontSize: 14,
              ),
            ),
            appBarTheme: const AppBarTheme(
              backgroundColor: Colors.transparent,
              foregroundColor: Colors.white,
              elevation: 0,
            ),
          ),
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

/// Wrapper widget that checks authentication state
class _AuthWrapper extends StatefulWidget {
  final Isar isar;

  const _AuthWrapper({required this.isar});

  @override
  State<_AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<_AuthWrapper> {
  bool _isLoading = true;
  bool _shouldShowLogin = false;

  @override
  void initState() {
    super.initState();
    _checkAuthState();

    // Listen to auth state changes
    AuthService.authStateChanges.listen((User? user) async {
      if (mounted) {
        setState(() {
          if (user != null) {
            _shouldShowLogin = false;
          }
          _isLoading = false;
        });

        // Sync data when user signs in
        if (user != null) {
          await _syncUserData();
        }
      }
    });
  }

  Future<void> _syncUserData() async {
    try {
      // Save anonymous watchlist and alerts to cache before loading account data
      await DataSyncService.saveWatchlistToCache(widget.isar);
      await DataSyncService.saveAlertsToCache(widget.isar);

      // Fetch account data (completely replaces local data)
      await AlertSyncService.fetchAndSyncAlerts(widget.isar);
      await AlertSyncService.syncPendingAlerts(widget.isar);
      await DataSyncService.fetchWatchlist(widget.isar);
    } catch (e) {
      // Silently handle errors - user can manually sync if needed
      debugPrint('_AuthWrapper: Error syncing user data: $e');
    }
  }

  Future<void> _checkAuthState() async {
    // Wait a bit for Firebase to initialize
    await Future.delayed(const Duration(milliseconds: 500));

    final prefs = await SharedPreferences.getInstance();
    final authSkipped = prefs.getBool('auth_skipped') ?? false;
    final isSignedIn = AuthService.isSignedIn;

    if (mounted) {
      setState(() {
        // Show login only on first launch (when not signed in and not skipped)
        _shouldShowLogin = !isSignedIn && !authSkipped;
        _isLoading = false;
      });
    }
  }

  void _onSignInSuccess() {
    setState(() {
      _shouldShowLogin = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    // Show login screen only on first launch
    if (_shouldShowLogin) {
      return LoginScreen(onSignInSuccess: _onSignInSuccess);
    }

    // Otherwise show home screen (authenticated or anonymous)
    return HomeScreen(isar: widget.isar);
  }
}
