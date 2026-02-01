import 'dart:convert';
import 'dart:io';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import 'notification_service.dart';

/// Service for working with Firebase
class FirebaseService {
  static FirebaseMessaging? _messaging;
  static String? _fcmToken;
  static String? _userId;

  /// Initialize Firebase (full initialization)
  static Future<void> initialize() async {
    try {
      // Check if Firebase is already initialized
      try {
        Firebase.app();
      } catch (_) {
        // Not initialized, initialize now
        await Firebase.initializeApp();
      }
      await initializeWithoutFirebaseInit();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error initializing Firebase: $e');
      }
    }
  }

  /// Initialize Firebase services without re-initializing Firebase itself
  /// Use this when Firebase is already initialized in main()
  static Future<void> initializeWithoutFirebaseInit() async {
    try {
      _messaging = FirebaseMessaging.instance;

      // Setup message handlers
      _setupMessageHandlers();

      // Get FCM token (don't block - can be slow)
      // Get token in background to avoid blocking app startup
      _getFcmToken().then((token) {
        if (kDebugMode && token != null) {
          debugPrint('FCM Token obtained: $token');
        }
      }).catchError((e) {
        if (kDebugMode) {
          debugPrint('Error getting FCM token in background: $e');
        }
      });

      if (kDebugMode) {
        debugPrint('Firebase services initialized');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error initializing Firebase services: $e');
      }
    }
  }

  /// Setup message handlers
  static void _setupMessageHandlers() {
    if (_messaging == null) return;

    // Handle messages when app is in background
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

    // Handle messages when app is open
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      if (kDebugMode) {
        debugPrint('Message received: ${message.messageId}');
        debugPrint('Data: ${message.data}');
        debugPrint('Notification: ${message.notification?.title}');
      }

      // Can show local notification here
      _handleForegroundMessage(message);
    });

    // Handle notification taps
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      if (kDebugMode) {
        debugPrint('App opened from notification: ${message.messageId}');
      }

      _handleNotificationTap(message);
    });

    // Check if app was opened from notification on startup
    _messaging!.getInitialMessage().then((RemoteMessage? message) {
      if (message != null) {
        if (kDebugMode) {
          debugPrint('App launched from notification: ${message.messageId}');
        }
        _handleNotificationTap(message);
      }
    });
  }

  /// Get FCM token
  static Future<String?> _getFcmToken() async {
    try {
      if (_messaging == null) return null;

      // IMPORTANT:
      // Do NOT request notification permission here.
      // On first install Android 13+ will show a system permission dialog.
      // If this is triggered during app startup/background init, it can lead to a "frozen" UI state.
      // Permission request is handled from UI (after first frame) instead.

      _fcmToken = await _messaging!.getToken();

      // Save token locally
      if (_fcmToken != null) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('fcm_token', _fcmToken!);
      }

      return _fcmToken;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error getting FCM token: $e');
      }
      return null;
    }
  }

  /// Get current FCM token
  static String? get fcmToken => _fcmToken;

  /// Set user ID
  static void setUserId(String userId) {
    _userId = userId;
  }

  /// Get user ID
  static String? get userId => _userId;

  /// Refresh FCM token
  static Future<void> refreshToken() async {
    try {
      if (_messaging == null) return;

      _fcmToken = await _messaging!.getToken();

      if (_fcmToken != null) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('fcm_token', _fcmToken!);

        // Can send token to server here
        await _sendTokenToServer();
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error refreshing FCM token: $e');
      }
    }
  }

  /// Register current device/token with backend without forcing permissions.
  static Future<void> registerDeviceWithServer() async {
    try {
      if (_fcmToken == null) {
        await _getFcmToken();
      }
      await _sendTokenToServer();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error registering device with server: $e');
      }
    }
  }

  /// Send token to server
  static Future<void> _sendTokenToServer() async {
    if (_fcmToken == null || _userId == null) return;

    try {
      const endpoint = '${AppConfig.apiBaseUrl}/device/register';
      final response = await http.post(
        Uri.parse(endpoint),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'deviceId': await _getDeviceId(),
          'fcmToken': _fcmToken,
          'platform': Platform.isAndroid
              ? 'android'
              : (Platform.isIOS ? 'ios' : 'unknown'),
          'userId': _userId,
        }),
      );

      if (response.statusCode == 200) {
        if (kDebugMode) {
          debugPrint('FCM token successfully sent to server');
        }
      } else {
        if (kDebugMode) {
          debugPrint('Error sending token: ${response.statusCode}');
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error sending token to server: $e');
      }
    }
  }

  /// Get unique device ID
  static Future<String> _getDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    String? deviceId = prefs.getString('device_id');

    if (deviceId == null) {
      // Generate new device ID
      deviceId =
          'device_${DateTime.now().millisecondsSinceEpoch}_${(1000 + (9999 - 1000) * (DateTime.now().millisecondsSinceEpoch % 10000) / 10000).round()}';
      await prefs.setString('device_id', deviceId);
    }

    return deviceId;
  }

  /// Expose device id for other services (ensures caching).
  static Future<String> getDeviceId() => _getDeviceId();

  /// Handle messages in background
  static Future<void> _firebaseMessagingBackgroundHandler(
      RemoteMessage message) async {
    // Filter out stale notifications (older than 10 minutes)
    if (!_isNotificationFresh(message)) {
      if (kDebugMode) {
        debugPrint('Skipping stale background notification: ${message.messageId}');
      }
      return;
    }

    final data = message.data;
    if (!data.containsKey('alert_id')) return;

    // When server sends notification payload, system already displays it (reliable on background).
    // Skip our localized build to avoid duplicate.
    if (message.notification != null) return;

    if (kDebugMode) {
      debugPrint('Showing background notification: ${message.messageId}');
    }

    // Build notification in user's language (data-only path)
    final isWatchlistAlert = data['isWatchlistAlert'] == 'true' ||
        data['isWatchlistAlert'] == true ||
        data['source'] == 'watchlist';

    await NotificationService.showRsiAlert(
      symbol: data['symbol'] ?? 'N/A',
      rsi: double.tryParse(data['rsi'] ?? '0') ?? 0.0,
      level: double.tryParse(data['level'] ?? '0') ?? 0.0,
      type: data['type'] ?? 'unknown',
      message: message.notification?.body ?? data['message'] ?? '',
      indicator: data['indicator'],
      timeframe: data['timeframe'],
      isWatchlistAlert: isWatchlistAlert,
    );
  }

  /// Handle messages in foreground
  static void _handleForegroundMessage(RemoteMessage message) {
    if (kDebugMode) {
      debugPrint('FCM foreground: handling message ${message.messageId}');
    }

    // Filter out stale notifications (older than 10 minutes)
    if (!_isNotificationFresh(message)) {
      if (kDebugMode) {
        debugPrint('FCM foreground: skipping stale notification (age > 10 min)');
      }
      return;
    }

    final data = message.data;
    if (!data.containsKey('alert_id')) {
      if (kDebugMode) {
        debugPrint('FCM foreground: no alert_id in data, skipping');
      }
      return;
    }

    // Foreground: always build our localized notification (ignore server notification if any)
    final isWatchlistAlert = data['isWatchlistAlert'] == 'true' ||
        data['isWatchlistAlert'] == true ||
        data['source'] == 'watchlist';

    try {
      NotificationService.showRsiAlert(
        symbol: data['symbol'] ?? 'N/A',
        rsi: double.tryParse(data['rsi'] ?? '0') ?? 0.0,
        level: double.tryParse(data['level'] ?? '0') ?? 0.0,
        type: data['type'] ?? 'unknown',
        message: message.notification?.body ?? data['message'] ?? '',
        indicator: data['indicator'],
        timeframe: data['timeframe'],
        isWatchlistAlert: isWatchlistAlert,
      );
      if (kDebugMode) {
        debugPrint('FCM foreground: showRsiAlert called for ${data['symbol']}');
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('FCM foreground: error showing notification: $e');
        debugPrint('Stack: $st');
      }
    }
  }

  /// Handle notification tap
  static void _handleNotificationTap(RemoteMessage message) {
    // Filter out stale notifications (older than 10 minutes)
    if (!_isNotificationFresh(message)) {
      if (kDebugMode) {
        debugPrint('Skipping stale notification tap: ${message.messageId}');
      }
      return;
    }

    final data = message.data;

    if (data.containsKey('alert_id')) {
      // Navigate to alert
      _navigateToAlert(data['alert_id']);
    } else if (data.containsKey('symbol')) {
      // Navigate to symbol
      _navigateToSymbol(data['symbol']);
    }
  }

  /// Check if notification is fresh (not older than maxAgeMinutes)
  static bool _isNotificationFresh(RemoteMessage message, {int maxAgeMinutes = 10}) {
    final data = message.data;
    final timestampStr = data['timestamp'];
    
    if (timestampStr == null) {
      // If no timestamp, assume it's fresh (backward compatibility)
      return true;
    }

    try {
      final timestamp = int.tryParse(timestampStr.toString());
      if (timestamp == null) {
        return true; // Assume fresh if can't parse
      }

      final now = DateTime.now().millisecondsSinceEpoch;
      final age = now - timestamp;
      final maxAgeMs = maxAgeMinutes * 60 * 1000;

      return age <= maxAgeMs;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error checking notification freshness: $e');
      }
      return true; // Assume fresh on error
    }
  }

  /// Navigate to alert
  static void _navigateToAlert(String alertId) {
    // Navigation is implemented through NotificationService on notification tap
    if (kDebugMode) {
      debugPrint(
          'Navigate to alert: $alertId (handled through NotificationService)');
    }
  }

  /// Navigate to symbol
  static void _navigateToSymbol(String symbol) {
    // Navigation is implemented through NotificationService on notification tap
    if (kDebugMode) {
      debugPrint(
          'Navigate to symbol: $symbol (handled through NotificationService)');
    }
  }

  /// Subscribe to topic
  static Future<void> subscribeToTopic(String topic) async {
    try {
      if (_messaging == null) return;

      await _messaging!.subscribeToTopic(topic);

      if (kDebugMode) {
        debugPrint('Subscribed to topic: $topic');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error subscribing to topic $topic: $e');
      }
    }
  }

  /// Unsubscribe from topic
  static Future<void> unsubscribeFromTopic(String topic) async {
    try {
      if (_messaging == null) return;

      await _messaging!.unsubscribeFromTopic(topic);

      if (kDebugMode) {
        debugPrint('Unsubscribed from topic: $topic');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error unsubscribing from topic $topic: $e');
      }
    }
  }

  /// Clear token
  static Future<void> clearToken() async {
    try {
      if (_messaging == null) return;

      await _messaging!.deleteToken();
      _fcmToken = null;

      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('fcm_token');

      if (kDebugMode) {
        debugPrint('FCM token cleared');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error clearing FCM token: $e');
      }
    }
  }
}

/// Background message handler (must be a global function)
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  await FirebaseService._firebaseMessagingBackgroundHandler(message);
}
