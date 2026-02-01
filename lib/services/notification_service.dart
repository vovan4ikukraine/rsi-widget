import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'dart:io';
import 'package:app_settings/app_settings.dart';
import 'package:isar/isar.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../main.dart';
import '../models.dart';
import '../screens/alerts_screen.dart';
import '../screens/home_screen.dart';
import '../localization/app_localizations.dart';

/// Service for local notifications
class NotificationService {
  static final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  static bool _initialized = false;

  /// Initialize notification service
  static Future<void> initialize() async {
    if (_initialized) return;

    try {
      // Settings for Android
      const androidSettings =
          AndroidInitializationSettings('@mipmap/ic_launcher');

      // Settings for iOS
      const iosSettings = DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      );

      const initSettings = InitializationSettings(
        android: androidSettings,
        iOS: iosSettings,
      );

      await _notifications.initialize(
        initSettings,
        onDidReceiveNotificationResponse: _onNotificationTapped,
      );

      // Don't request permissions automatically on initialization
      // Permissions will be requested only when really needed
      // if (Platform.isAndroid) {
      //   await _requestAndroidPermissions();
      // }

      _initialized = true;

      if (kDebugMode) {
        debugPrint('Notification service initialized');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error initializing notifications: $e');
      }
    }
  }

  /// Request permissions only when needed (e.g., when creating an alert)
  static Future<bool> requestPermissionsIfNeeded() async {
    try {
      final androidPlugin =
          _notifications.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();

      if (androidPlugin != null) {
        // Request notification permission only when really needed
        // Don't request exact alarm permission automatically,
        // as this opens system settings
        await androidPlugin.requestNotificationsPermission();
        return true;
      }
      return false;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error requesting Android permissions: $e');
      }
      return false;
    }
  }

  /// Ask for notification permission once on first app open (Android 13+).
  /// Runs from UI layer (after first frame) to avoid "frozen" interaction issues.
  static Future<void> requestOnFirstAppOpenIfNeeded() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final alreadyAsked = prefs.getBool('notif_permission_asked') ?? false;
      if (alreadyAsked) return;

      await prefs.setBool('notif_permission_asked', true);

      // Ensure plugin is initialized before requesting.
      if (!_initialized) {
        await initialize();
      }

      if (Platform.isAndroid) {
        final androidPlugin =
            _notifications.resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>();
        await androidPlugin?.requestNotificationsPermission();
      }
      // iOS already requests via DarwinInitializationSettings if enabled.
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error requesting notifications on first app open: $e');
      }
    }
  }

  /// Handle notification tap
  static void _onNotificationTapped(NotificationResponse response) {
    if (kDebugMode) {
      debugPrint('Notification tapped: ${response.payload}');
    }

    final payload = response.payload;
    if (payload != null) {
      _handleNotificationPayload(payload);
    }
  }

  /// Handle notification payload
  static void _handleNotificationPayload(String payload) async {
    try {
      // Parse payload (can be JSON string or Map as string)
      Map<String, dynamic>? data;

      // Try to parse as JSON
      try {
        final decoded = json.decode(payload);
        if (decoded is Map<String, dynamic>) {
          data = decoded;
        }
      } catch (e) {
        // If not JSON, try to parse as string format "{key: value, ...}"
        if (payload.startsWith('{') && payload.endsWith('}')) {
          // Simple parsing for FlutterLocalNotifications format
          data = _parseSimpleMap(payload);
        }
      }

      if (data == null) {
        if (kDebugMode) {
          debugPrint('Failed to parse payload: $payload');
        }
        return;
      }

      // Navigate based on notification type
      if (data.containsKey('type')) {
        final type = data['type'];
        if (type is! String) return;

        if (type == 'rsi_alert' || data.containsKey('symbol')) {
          final symbol = data['symbol'];
          final indicator = data['indicator']; // Get indicator from payload
          await _navigateToSymbol(
            symbol is String ? symbol : 'AAPL',
            indicator is String ? indicator : null,
          );
        } else if (data.containsKey('alert_id')) {
          final alertId = data['alert_id'];
          if (alertId is String) {
            await _navigateToAlert(alertId);
          }
        }
      } else if (data.containsKey('symbol')) {
        final symbol = data['symbol'];
        final indicator = data['indicator']; // Get indicator from payload
        if (symbol is String) {
          await _navigateToSymbol(
            symbol,
            indicator is String ? indicator : null,
          );
        }
      }

      if (kDebugMode) {
        debugPrint('Navigation completed for payload: $data');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error processing payload: $e');
      }
    }
  }

  /// Simple parsing of Map format string
  static Map<String, dynamic>? _parseSimpleMap(String str) {
    try {
      // Remove curly braces
      final content = str.substring(1, str.length - 1);
      final Map<String, dynamic> result = {};

      // Simple key-value parsing
      final pairs = content.split(',');
      for (final pair in pairs) {
        final parts = pair.split(':');
        if (parts.length == 2) {
          final key = parts[0].trim().replaceAll("'", "").replaceAll('"', '');
          var value = parts[1].trim().replaceAll("'", "").replaceAll('"', '');
          result[key] = value;
        }
      }

      return result;
    } catch (e) {
      return null;
    }
  }

  /// Navigate to symbol
  static Future<void> _navigateToSymbol(String symbol, String? indicator) async {
    try {
      final navigator = RSIWidgetApp.navigatorKey.currentState;
      if (navigator == null) return;

      // Get Isar from path
      final dir = await getApplicationDocumentsDirectory();
      final isar = await Isar.open(
        [
          AlertRuleSchema,
          AlertStateSchema,
          AlertEventSchema,
          IndicatorDataSchema,
          DeviceInfoSchema
        ],
        directory: dir.path,
        name: 'rsi_alert_db',
      );

      navigator.push(
        MaterialPageRoute(
          builder: (context) => HomeScreen(
            isar: isar,
            initialSymbol: symbol,
            initialIndicator: indicator,
          ),
        ),
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error navigating to symbol $symbol: $e');
      }
    }
  }

  /// Navigate to alert
  static Future<void> _navigateToAlert(String alertId) async {
    try {
      final navigator = RSIWidgetApp.navigatorKey.currentState;
      if (navigator == null) return;

      // Get Isar from path
      final dir = await getApplicationDocumentsDirectory();
      final isar = await Isar.open(
        [
          AlertRuleSchema,
          AlertStateSchema,
          AlertEventSchema,
          IndicatorDataSchema,
          DeviceInfoSchema
        ],
        directory: dir.path,
        name: 'rsi_alert_db',
      );

      navigator.push(
        MaterialPageRoute(
          builder: (context) => AlertsScreen(isar: isar),
        ),
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error navigating to alert $alertId: $e');
      }
    }
  }

  /// Show RSI alert
  static Future<void> showRsiAlert({
    required String symbol,
    required double rsi,
    required double level,
    required String type,
    String? message,
    String? indicator,
    String? timeframe,
    bool isWatchlistAlert = false,
  }) async {
    if (!_initialized) {
      await initialize();
    }

    try {
      // Get language from SharedPreferences for localization (default en as fallback)
      final prefs = await SharedPreferences.getInstance();
      final languageCode = prefs.getString('language') ?? 'en';
      final soundEnabled = prefs.getBool('sound_enabled') ?? true;
      final vibrationEnabled = prefs.getBool('vibration_enabled') ?? true;

      // Build title based on alert type
      String title;
      if (isWatchlistAlert) {
        // Watchlist Alert: "Watchlist: AAPL"
        title = await AppLocalizations.tByLanguage(
          languageCode,
          'notification_watchlist_title',
          params: {'symbol': symbol},
        );
      } else {
        // Custom Alert: just "AAPL" or "Alert: AAPL"
        title = await AppLocalizations.tByLanguage(
          languageCode,
          'notification_alert_title',
          params: {'symbol': symbol},
        );
      }
      
      // Add timeframe to title if available
      if (timeframe != null && timeframe.isNotEmpty) {
        title = '$title ($timeframe)';
      }

      // Always build body from localized templates so notifications appear in user language
      // Server sends type: cross_up, cross_down, enter_zone, exit_zone (not above/below)
      final indicatorName = (indicator ?? 'RSI').toUpperCase();
      final levelStr = level.toStringAsFixed(0);
      final rsiStr = rsi.toStringAsFixed(2);
      String body;
      if (type == 'cross_up' || type == 'above') {
        body = await AppLocalizations.tByLanguage(
          languageCode,
          'alert_message_cross_up',
          params: {'indicator': indicatorName, 'level': levelStr, 'rsi': rsiStr},
        );
      } else if (type == 'cross_down' || type == 'below') {
        body = await AppLocalizations.tByLanguage(
          languageCode,
          'alert_message_cross_down',
          params: {'indicator': indicatorName, 'level': levelStr, 'rsi': rsiStr},
        );
      } else if (type == 'enter_zone' || type == 'exit_zone') {
        // Zone enter/exit: use generic body with localized type
        final typeKey = type == 'enter_zone' ? 'alert_message_cross_up' : 'alert_message_cross_down';
        body = await AppLocalizations.tByLanguage(
          languageCode,
          typeKey,
          params: {'indicator': indicatorName, 'level': levelStr, 'rsi': rsiStr},
        );
      } else {
        final typeKey = type == 'between' ? 'alert_between' : (type == 'above' ? 'alert_above' : 'alert_below');
        final typeLocalized = await AppLocalizations.tByLanguage(languageCode, typeKey);
        body = await AppLocalizations.tByLanguage(
          languageCode,
          'notification_rsi_alert_body',
          params: {
            'rsi': rsiStr,
            'level': levelStr,
            'type': typeLocalized,
          },
        );
      }

      final channelName = await AppLocalizations.tByLanguage(
        languageCode,
        'notification_channel_rsi_alerts',
      );
      final channelDesc = await AppLocalizations.tByLanguage(
        languageCode,
        'notification_channel_rsi_alerts_desc',
      );

      final androidDetails = AndroidNotificationDetails(
        'rsi_alerts',
        channelName,
        channelDescription: channelDesc,
        importance: Importance.high,
        priority: Priority.high,
        showWhen: true,
        enableVibration: vibrationEnabled,
        playSound: soundEnabled,
        icon: '@mipmap/ic_launcher',
      );

      final iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: soundEnabled,
        sound: soundEnabled ? 'default' : null,
      );

      final details = NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      );

      final payload = {
        'type': 'rsi_alert',
        'symbol': symbol,
        'rsi': rsi.toString(),
        'level': level.toString(),
        'alert_type': type,
        if (indicator != null) 'indicator': indicator,
      };

      await _notifications.show(
        symbol.hashCode,
        title,
        body,
        details,
        payload: json.encode(payload),
      );

      if (kDebugMode) {
        debugPrint('RSI notification shown for $symbol');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error showing RSI notification: $e');
      }
    }
  }

  /// Show general notification
  static Future<void> showNotification({
    required String title,
    required String body,
    String? payload,
    int? id,
  }) async {
    if (!_initialized) {
      await initialize();
    }

    try {
      // Get language from SharedPreferences for localization
      final prefs = await SharedPreferences.getInstance();
      final languageCode = prefs.getString('language') ?? 'en';
      final soundEnabled = prefs.getBool('sound_enabled') ?? true;
      final vibrationEnabled = prefs.getBool('vibration_enabled') ?? true;

      final channelName = await AppLocalizations.tByLanguage(
        languageCode,
        'notification_channel_general',
      );
      final channelDesc = await AppLocalizations.tByLanguage(
        languageCode,
        'notification_channel_general_desc',
      );

      final androidDetails = AndroidNotificationDetails(
        'general',
        channelName,
        channelDescription: channelDesc,
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
        showWhen: true,
        enableVibration: vibrationEnabled,
        playSound: soundEnabled,
      );

      final iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: soundEnabled,
        sound: soundEnabled ? 'default' : null,
      );

      final details = NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      );

      await _notifications.show(
        id ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
        title,
        body,
        details,
        payload: payload,
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error showing notification: $e');
      }
    }
  }

  /// Show connection notification
  static Future<void> showConnectionNotification({
    required bool connected,
    String? message,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final languageCode = prefs.getString('language') ?? 'en';

    final title = await AppLocalizations.tByLanguage(
      languageCode,
      connected ? 'notification_connected_title' : 'notification_disconnected_title',
    );
    final body = message ??
        await AppLocalizations.tByLanguage(
          languageCode,
          connected ? 'notification_receiving_data' : 'notification_check_connection',
        );

    await showNotification(
      title: title,
      body: body,
      payload: 'connection_${connected ? 'on' : 'off'}',
    );
  }

  /// Show error notification
  static Future<void> showErrorNotification({
    required String error,
    String? details,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final languageCode = prefs.getString('language') ?? 'en';

    final title = await AppLocalizations.tByLanguage(
      languageCode,
      'notification_error_title',
    );

    await showNotification(
      title: title,
      body: details ?? error,
      payload: 'error',
    );
  }

  /// Show sync notification
  static Future<void> showSyncNotification({
    required String symbol,
    required bool success,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final languageCode = prefs.getString('language') ?? 'en';

    final title = await AppLocalizations.tByLanguage(
      languageCode,
      success ? 'notification_sync_success_title' : 'notification_sync_error_title',
    );
    final body = await AppLocalizations.tByLanguage(
      languageCode,
      success ? 'notification_sync_success_body' : 'notification_sync_error_body',
      params: {'symbol': symbol},
    );

    await showNotification(
      title: title,
      body: body,
      payload: 'sync_${success ? 'success' : 'error'}_$symbol',
    );
  }

  /// Cancel all notifications
  static Future<void> cancelAllNotifications() async {
    try {
      await _notifications.cancelAll();

      if (kDebugMode) {
        debugPrint('All notifications cancelled');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error cancelling notifications: $e');
      }
    }
  }

  /// Cancel notification by ID
  static Future<void> cancelNotification(int id) async {
    try {
      await _notifications.cancel(id);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error cancelling notification $id: $e');
      }
    }
  }

  /// Cancel notifications by "tag" (emulated via hashCode)
  static Future<void> cancelNotificationsByTag(String tag) async {
    try {
      // Generate ID from string - same for one tag
      final id = tag.hashCode.abs() % 1000000;
      await _notifications.cancel(id);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error cancelling notifications by tag $tag: $e');
      }
    }
  }

  /// Get active notifications
  static Future<List<ActiveNotification>> getActiveNotifications() async {
    try {
      return await _notifications.getActiveNotifications();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error getting active notifications: $e');
      }
      return [];
    }
  }

  /// Check if notifications are enabled
  static Future<bool> areNotificationsEnabled() async {
    try {
      if (Platform.isAndroid) {
        final androidPlugin =
            _notifications.resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>();

        if (androidPlugin != null) {
          return await androidPlugin.areNotificationsEnabled() ?? false;
        }
      }
      return true; // For iOS assume they are enabled
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error checking notification status: $e');
      }
      return false;
    }
  }

  /// Open notification settings
  static Future<void> openNotificationSettings() async {
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        await AppSettings.openAppSettings(
          type: AppSettingsType.notification,
        );
      } else {
        if (kDebugMode) {
          debugPrint('Opening settings is supported only on Android/iOS');
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error opening notification settings: $e');
      }
    }
  }
}
