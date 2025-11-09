import 'dart:convert';
import 'dart:io';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'notification_service.dart';

/// Service for working with Firebase
class FirebaseService {
  static FirebaseMessaging? _messaging;
  static String? _fcmToken;
  static String? _userId;

  /// Initialize Firebase
  static Future<void> initialize() async {
    try {
      await Firebase.initializeApp();
      _messaging = FirebaseMessaging.instance;

      // Setup message handlers
      _setupMessageHandlers();

      // Get FCM token
      await _getFcmToken();

      if (kDebugMode) {
        print('Firebase initialized');
        print('FCM Token: $_fcmToken');
      }
    } catch (e) {
      if (kDebugMode) {
        print('Error initializing Firebase: $e');
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
        print('Message received: ${message.messageId}');
        print('Data: ${message.data}');
        print('Notification: ${message.notification?.title}');
      }

      // Can show local notification here
      _handleForegroundMessage(message);
    });

    // Handle notification taps
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      if (kDebugMode) {
        print('App opened from notification: ${message.messageId}');
      }

      _handleNotificationTap(message);
    });

    // Check if app was opened from notification on startup
    _messaging!.getInitialMessage().then((RemoteMessage? message) {
      if (message != null) {
        if (kDebugMode) {
          print('App launched from notification: ${message.messageId}');
        }
        _handleNotificationTap(message);
      }
    });
  }

  /// Get FCM token
  static Future<String?> _getFcmToken() async {
    try {
      if (_messaging == null) return null;

      // Request permissions
      await _messaging!.requestPermission(
        alert: true,
        announcement: false,
        badge: true,
        carPlay: false,
        criticalAlert: false,
        provisional: false,
        sound: true,
      );

      _fcmToken = await _messaging!.getToken();

      // Save token locally
      if (_fcmToken != null) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('fcm_token', _fcmToken!);
      }

      return _fcmToken;
    } catch (e) {
      if (kDebugMode) {
        print('Error getting FCM token: $e');
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
        print('Error refreshing FCM token: $e');
      }
    }
  }

  /// Send token to server
  static Future<void> _sendTokenToServer() async {
    if (_fcmToken == null || _userId == null) return;

    try {
      const endpoint =
          'https://rsi-workers.vovan4ikukraine.workers.dev/device/register';
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
          print('FCM token successfully sent to server');
        }
      } else {
        if (kDebugMode) {
          print('Error sending token: ${response.statusCode}');
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('Error sending token to server: $e');
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

  /// Handle messages in background
  static Future<void> _firebaseMessagingBackgroundHandler(
      RemoteMessage message) async {
    if (kDebugMode) {
      print('Handling message in background: ${message.messageId}');
    }

    // Can process message data here
    final data = message.data;
    if (data.containsKey('alert_id')) {
      // Handle alert
      _handleAlertData(data);
    }
  }

  /// Handle messages in foreground
  static void _handleForegroundMessage(RemoteMessage message) {
    // Show local notification via NotificationService
    final notification = message.notification;
    final data = message.data;

    if (notification != null) {
      NotificationService.showRsiAlert(
        symbol: data['symbol'] ?? 'N/A',
        rsi: double.tryParse(data['rsi'] ?? '0') ?? 0.0,
        level: double.tryParse(data['level'] ?? '0') ?? 0.0,
        type: data['type'] ?? 'unknown',
        message: notification.body ?? data['message'],
      );
    }
  }

  /// Handle notification tap
  static void _handleNotificationTap(RemoteMessage message) {
    final data = message.data;

    if (data.containsKey('alert_id')) {
      // Navigate to alert
      _navigateToAlert(data['alert_id']);
    } else if (data.containsKey('symbol')) {
      // Navigate to symbol
      _navigateToSymbol(data['symbol']);
    }
  }

  /// Handle alert data
  static void _handleAlertData(Map<String, dynamic> data) {
    // Alert data is processed automatically through NotificationService
    // when receiving notification in background
    if (kDebugMode) {
      print('Handling alert: $data');
    }
  }

  /// Navigate to alert
  static void _navigateToAlert(String alertId) {
    // Navigation is implemented through NotificationService on notification tap
    if (kDebugMode) {
      print(
          'Navigate to alert: $alertId (handled through NotificationService)');
    }
  }

  /// Navigate to symbol
  static void _navigateToSymbol(String symbol) {
    // Navigation is implemented through NotificationService on notification tap
    if (kDebugMode) {
      print(
          'Navigate to symbol: $symbol (handled through NotificationService)');
    }
  }

  /// Subscribe to topic
  static Future<void> subscribeToTopic(String topic) async {
    try {
      if (_messaging == null) return;

      await _messaging!.subscribeToTopic(topic);

      if (kDebugMode) {
        print('Subscribed to topic: $topic');
      }
    } catch (e) {
      if (kDebugMode) {
        print('Error subscribing to topic $topic: $e');
      }
    }
  }

  /// Unsubscribe from topic
  static Future<void> unsubscribeFromTopic(String topic) async {
    try {
      if (_messaging == null) return;

      await _messaging!.unsubscribeFromTopic(topic);

      if (kDebugMode) {
        print('Unsubscribed from topic: $topic');
      }
    } catch (e) {
      if (kDebugMode) {
        print('Error unsubscribing from topic $topic: $e');
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
        print('FCM token cleared');
      }
    } catch (e) {
      if (kDebugMode) {
        print('Error clearing FCM token: $e');
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
