import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:isar/isar.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'di/app_container.dart';
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
import 'dart:async';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1️⃣ Initialize Firebase (critical for auth)
  await Firebase.initializeApp();

  // 2️⃣ Get path for local database (Isar requires directory) - quick operation
  final dir = await getApplicationDocumentsDirectory();

  // 3️⃣ Initialize Isar - can be slow on large databases, but necessary
  final isar = await Isar.open(
    [
      AlertRuleSchema,
      AlertStateSchema,
      AlertEventSchema,
      IndicatorDataSchema,
      DeviceInfoSchema,
      WatchlistItemSchema,
    ],
    directory: dir.path,
    name: 'rsi_alert_db',
  );

  // 3a Register DI (Isar, repositories)
  registerAppDependencies(isar);

  // 4️⃣ Load preferences (quick)
  final prefs = await SharedPreferences.getInstance();
  final languageCode = prefs.getString('language') ?? 'ru';
  final theme = prefs.getString('theme') ?? 'dark';
  final appState = AppState(
    locale: Locale(languageCode),
    themeMode: theme == 'light' ? ThemeMode.light : ThemeMode.dark,
  );

  // 5️⃣ Launch application immediately
  runApp(
    AppStateScope(
      notifier: appState,
      child: RSIWidgetApp(isar: isar, appState: appState),
    ),
  );

  // 6️⃣ Initialize non-critical services in background (don't block UI)
  // These can be initialized after app is shown
  unawaited(_initializeServicesInBackground());
}

/// Initialize services that are not critical for showing the UI
Future<void> _initializeServicesInBackground() async {
  try {
    // Initialize services in parallel where possible
    await Future.wait([
      NotificationService.initialize(),
      FirebaseService.initializeWithoutFirebaseInit(), // Don't re-init Firebase
    ]);

    // UserService depends on FirebaseService, so initialize after
    await UserService.initialize();
  } catch (e) {
    // Silently handle errors - services will be initialized when needed
    debugPrint('Error initializing services in background: $e');
  }
}

class RSIWidgetApp extends StatefulWidget {
  final Isar isar;
  final AppState appState;
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  const RSIWidgetApp({super.key, required this.isar, required this.appState});

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
              seedColor: const Color(0xFF2563EB), // Modern blue
              brightness: Brightness.light,
            ),
            scaffoldBackgroundColor: const Color(0xFFE8EAED), // Darker background for better contrast
            cardTheme: CardThemeData(
              color: Colors.white,
              elevation: 3, // Visible shadow
              shadowColor: Colors.black.withValues(alpha: 0.1), // Shadow
              surfaceTintColor: Colors.transparent,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                // Removed border to avoid double-layer effect
              ),
              margin: const EdgeInsets.only(bottom: 12, left: 8, right: 8),
            ),
            inputDecorationTheme: InputDecorationTheme(
              filled: true,
              fillColor: const Color(0xFFF8F9FA), // Light gray background to distinguish from cards
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(
                  color: Colors.grey.withValues(alpha: 0.3), // More visible border
                  width: 1,
                ),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(
                  color: Colors.grey.withValues(alpha: 0.3), // More visible border
                  width: 1,
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(
                  color: Color(0xFF2563EB), // Modern blue
                  width: 2,
                ),
              ),
              errorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(
                  color: Colors.red.withValues(alpha: 0.5),
                  width: 1,
                ),
              ),
              focusedErrorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(
                  color: Colors.red,
                  width: 2,
                ),
              ),
              labelStyle: TextStyle(
                overflow: TextOverflow.visible,
                color: Colors.grey[700], // Better contrast
              ),
              floatingLabelStyle: const TextStyle(
                color: Color(0xFF2563EB),
              ),
              floatingLabelBehavior: FloatingLabelBehavior.always,
              isDense: false,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            ),
            dropdownMenuTheme: DropdownMenuThemeData(
              textStyle: const TextStyle(
                color: Color(0xFF1F2937), // Darker, better contrast
                fontSize: 14,
              ),
              menuStyle: MenuStyle(
                backgroundColor: WidgetStateProperty.all(Colors.white),
                elevation: WidgetStateProperty.all(8),
                shadowColor: WidgetStateProperty.all(
                  Colors.black.withValues(alpha: 0.1),
                ),
              ),
            ),
            appBarTheme: AppBarTheme(
              backgroundColor: Colors.white, // Clean white app bar
              foregroundColor: const Color(0xFF1F2937), // Dark text
              elevation: 0,
              surfaceTintColor: Colors.transparent,
              shadowColor: Colors.black.withValues(alpha: 0.05),
              scrolledUnderElevation: 1,
            ),
            dividerTheme: DividerThemeData(
              color: Colors.grey.withValues(alpha: 0.12),
              thickness: 1,
              space: 1,
            ),
            listTileTheme: ListTileThemeData(
              tileColor: Colors.white,
              selectedTileColor: const Color(0xFF2563EB).withValues(alpha: 0.08),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            elevatedButtonTheme: ElevatedButtonThemeData(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2563EB),
                foregroundColor: Colors.white,
                elevation: 2,
                shadowColor: Colors.black.withValues(alpha: 0.1),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
            ),
            iconButtonTheme: IconButtonThemeData(
              style: IconButton.styleFrom(
                foregroundColor: const Color(0xFF1F2937),
              ),
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
                  color: Colors.blue.withValues(alpha: 0.5),
                  width: 1.5,
                ),
              ),
              labelStyle: const TextStyle(
                overflow: TextOverflow.visible,
              ),
              floatingLabelBehavior: FloatingLabelBehavior.always,
              isDense: false,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
            ),
            dropdownMenuTheme: const DropdownMenuThemeData(
              textStyle: TextStyle(color: Colors.white, fontSize: 14),
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
              );
            }
            // Handle navigation to home with symbol
            if (settings.name == '/home') {
              final args = settings.arguments as Map<String, dynamic>?;
              return MaterialPageRoute(
                builder: (context) => HomeScreen(
                  isar: widget.isar,
                  initialSymbol: args?['symbol'] as String?,
                ),
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
    debugPrint('_AuthWrapper._syncUserData: Starting sync...');
    try {
      // Save anonymous watchlist and alerts to cache before loading account data
      await DataSyncService.saveWatchlistToCache();
      await DataSyncService.saveAlertsToCache();

      // Fetch account data (completely replaces local data)
      await AlertSyncService.fetchAndSyncAlerts();
      await AlertSyncService.syncPendingAlerts();
      
      debugPrint('_AuthWrapper._syncUserData: Calling fetchWatchlist...');
      await DataSyncService.fetchWatchlist();
      debugPrint('_AuthWrapper._syncUserData: Sync complete');
    } catch (e, stackTrace) {
      // Silently handle errors - user can manually sync if needed
      debugPrint('_AuthWrapper._syncUserData: Error syncing user data: $e');
      debugPrint('$stackTrace');
    }
  }

  Future<void> _checkAuthState() async {
    // Check auth state immediately (Firebase is already initialized in main)
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
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    // Show login screen only on first launch
    if (_shouldShowLogin) {
      return LoginScreen(onSignInSuccess: _onSignInSuccess);
    }

    // Otherwise show home screen (authenticated or anonymous)
    return HomeScreen(isar: widget.isar);
  }
}
