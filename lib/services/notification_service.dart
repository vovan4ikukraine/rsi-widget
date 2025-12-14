import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'dart:io';
import 'package:app_settings/app_settings.dart';
import 'package:isar/isar.dart';
import 'package:path_provider/path_provider.dart';
import '../main.dart';
import '../models.dart';
import '../screens/alerts_screen.dart';
import '../screens/home_screen.dart';

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
        print('Notification service initialized');
      }
    } catch (e) {
      if (kDebugMode) {
        print('Error initializing notifications: $e');
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
        print('Error requesting Android permissions: $e');
      }
      return false;
    }
  }

  /// Handle notification tap
  static void _onNotificationTapped(NotificationResponse response) {
    if (kDebugMode) {
      print('Notification tapped: ${response.payload}');
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
          print('Failed to parse payload: $payload');
        }
        return;
      }

      // Navigate based on notification type
      if (data.containsKey('type')) {
        final type = data['type'];
        if (type is! String) return;

        if (type == 'rsi_alert' || data.containsKey('symbol')) {
          final symbol = data['symbol'];
          await _navigateToSymbol(symbol is String ? symbol : 'AAPL');
        } else if (data.containsKey('alert_id')) {
          final alertId = data['alert_id'];
          if (alertId is String) {
            await _navigateToAlert(alertId);
          }
        }
      } else if (data.containsKey('symbol')) {
        final symbol = data['symbol'];
        if (symbol is String) {
          await _navigateToSymbol(symbol);
        }
      }

      if (kDebugMode) {
        print('Navigation completed for payload: $data');
      }
    } catch (e) {
      if (kDebugMode) {
        print('Error processing payload: $e');
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
  static Future<void> _navigateToSymbol(String symbol) async {
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
          builder: (context) => HomeScreen(isar: isar, initialSymbol: symbol),
        ),
      );
    } catch (e) {
      if (kDebugMode) {
        print('Error navigating to symbol $symbol: $e');
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
        print('Error navigating to alert $alertId: $e');
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
  }) async {
    if (!_initialized) {
      await initialize();
    }

    try {
      final title = 'Watchlist: $symbol';
      final body = message ?? 'RSI $rsi crossed level $level ($type)';

      const androidDetails = AndroidNotificationDetails(
        'rsi_alerts',
        'RSI Alerts',
        channelDescription: 'Notifications about RSI level crossings',
        importance: Importance.high,
        priority: Priority.high,
        showWhen: true,
        enableVibration: true,
        playSound: true,
        icon: '@mipmap/ic_launcher',
      );

      const iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        sound: 'default',
      );

      const details = NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      );

      final payload = {
        'type': 'rsi_alert',
        'symbol': symbol,
        'rsi': rsi.toString(),
        'level': level.toString(),
        'alert_type': type,
      };

      await _notifications.show(
        symbol.hashCode,
        title,
        body,
        details,
        payload: json.encode(payload),
      );

      if (kDebugMode) {
        print('RSI notification shown for $symbol');
      }
    } catch (e) {
      if (kDebugMode) {
        print('Error showing RSI notification: $e');
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
      const androidDetails = AndroidNotificationDetails(
        'general',
        'General Notifications',
        channelDescription: 'General application notifications',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
        showWhen: true,
      );

      const iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      );

      const details = NotificationDetails(
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
        print('Error showing notification: $e');
      }
    }
  }

  /// Show connection notification
  static Future<void> showConnectionNotification({
    required bool connected,
    String? message,
  }) async {
    final title =
        connected ? 'Connected to server' : 'Disconnected from server';
    final body = message ??
        (connected ? 'Receiving RSI data' : 'Check internet connection');

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
    await showNotification(
      title: 'Application error',
      body: details ?? error,
      payload: 'error',
    );
  }

  /// Show sync notification
  static Future<void> showSyncNotification({
    required String symbol,
    required bool success,
  }) async {
    final title = success ? 'Data synchronized' : 'Synchronization error';
    final body = success
        ? 'RSI data for $symbol updated'
        : 'Failed to update data for $symbol';

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
        print('All notifications cancelled');
      }
    } catch (e) {
      if (kDebugMode) {
        print('Error cancelling notifications: $e');
      }
    }
  }

  /// Cancel notification by ID
  static Future<void> cancelNotification(int id) async {
    try {
      await _notifications.cancel(id);
    } catch (e) {
      if (kDebugMode) {
        print('Error cancelling notification $id: $e');
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
        print('Error cancelling notifications by tag $tag: $e');
      }
    }
  }

  /// Get active notifications
  static Future<List<ActiveNotification>> getActiveNotifications() async {
    try {
      return await _notifications.getActiveNotifications();
    } catch (e) {
      if (kDebugMode) {
        print('Error getting active notifications: $e');
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
        print('Error checking notification status: $e');
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
          print('Opening settings is supported only on Android/iOS');
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('Error opening notification settings: $e');
      }
    }
  }
}
