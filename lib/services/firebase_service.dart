import 'dart:convert';
import 'dart:io';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'notification_service.dart';

/// Сервис для работы с Firebase
class FirebaseService {
  static FirebaseMessaging? _messaging;
  static String? _fcmToken;
  static String? _userId;

  /// Инициализация Firebase
  static Future<void> initialize() async {
    try {
      await Firebase.initializeApp();
      _messaging = FirebaseMessaging.instance;

      // Настройка обработчиков сообщений
      _setupMessageHandlers();

      // Получение FCM токена
      await _getFcmToken();

      if (kDebugMode) {
        print('Firebase инициализирован');
        print('FCM Token: $_fcmToken');
      }
    } catch (e) {
      if (kDebugMode) {
        print('Ошибка инициализации Firebase: $e');
      }
    }
  }

  /// Настройка обработчиков сообщений
  static void _setupMessageHandlers() {
    if (_messaging == null) return;

    // Обработка сообщений когда приложение в фоне
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

    // Обработка сообщений когда приложение открыто
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      if (kDebugMode) {
        print('Получено сообщение: ${message.messageId}');
        print('Данные: ${message.data}');
        print('Уведомление: ${message.notification?.title}');
      }

      // Здесь можно показать локальное уведомление
      _handleForegroundMessage(message);
    });

    // Обработка нажатий на уведомления
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      if (kDebugMode) {
        print('Приложение открыто из уведомления: ${message.messageId}');
      }

      _handleNotificationTap(message);
    });

    // Проверка, было ли приложение открыто из уведомления при запуске
    _messaging!.getInitialMessage().then((RemoteMessage? message) {
      if (message != null) {
        if (kDebugMode) {
          print('Приложение запущено из уведомления: ${message.messageId}');
        }
        _handleNotificationTap(message);
      }
    });
  }

  /// Получение FCM токена
  static Future<String?> _getFcmToken() async {
    try {
      if (_messaging == null) return null;

      // Запрос разрешений
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

      // Сохранение токена локально
      if (_fcmToken != null) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('fcm_token', _fcmToken!);
      }

      return _fcmToken;
    } catch (e) {
      if (kDebugMode) {
        print('Ошибка получения FCM токена: $e');
      }
      return null;
    }
  }

  /// Получение текущего FCM токена
  static String? get fcmToken => _fcmToken;

  /// Установка пользователя
  static void setUserId(String userId) {
    _userId = userId;
  }

  /// Получение ID пользователя
  static String? get userId => _userId;

  /// Обновление FCM токена
  static Future<void> refreshToken() async {
    try {
      if (_messaging == null) return;

      _fcmToken = await _messaging!.getToken();

      if (_fcmToken != null) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('fcm_token', _fcmToken!);

        // Здесь можно отправить токен на сервер
        await _sendTokenToServer();
      }
    } catch (e) {
      if (kDebugMode) {
        print('Ошибка обновления FCM токена: $e');
      }
    }
  }

  /// Отправка токена на сервер
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
          print('FCM токен успешно отправлен на сервер');
        }
      } else {
        if (kDebugMode) {
          print('Ошибка отправки токена: ${response.statusCode}');
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('Ошибка отправки токена на сервер: $e');
      }
    }
  }

  /// Получение уникального ID устройства
  static Future<String> _getDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    String? deviceId = prefs.getString('device_id');

    if (deviceId == null) {
      // Генерируем новый ID устройства
      deviceId =
          'device_${DateTime.now().millisecondsSinceEpoch}_${(1000 + (9999 - 1000) * (DateTime.now().millisecondsSinceEpoch % 10000) / 10000).round()}';
      await prefs.setString('device_id', deviceId);
    }

    return deviceId;
  }

  /// Обработка сообщений в фоне
  static Future<void> _firebaseMessagingBackgroundHandler(
      RemoteMessage message) async {
    if (kDebugMode) {
      print('Обработка сообщения в фоне: ${message.messageId}');
    }

    // Здесь можно обработать данные сообщения
    final data = message.data;
    if (data.containsKey('alert_id')) {
      // Обработка алерта
      _handleAlertData(data);
    }
  }

  /// Обработка сообщений в переднем плане
  static void _handleForegroundMessage(RemoteMessage message) {
    // Показать локальное уведомление через NotificationService
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

  /// Обработка нажатия на уведомление
  static void _handleNotificationTap(RemoteMessage message) {
    final data = message.data;

    if (data.containsKey('alert_id')) {
      // Переход к алерту
      _navigateToAlert(data['alert_id']);
    } else if (data.containsKey('symbol')) {
      // Переход к символу
      _navigateToSymbol(data['symbol']);
    }
  }

  /// Обработка данных алерта
  static void _handleAlertData(Map<String, dynamic> data) {
    // Данные алерта обрабатываются автоматически через NotificationService
    // при получении уведомления в фоне
    if (kDebugMode) {
      print('Обработка алерта: $data');
    }
  }

  /// Навигация к алерту
  static void _navigateToAlert(String alertId) {
    // Навигация реализована через NotificationService при нажатии на уведомление
    if (kDebugMode) {
      print(
          'Навигация к алерту: $alertId (обрабатывается через NotificationService)');
    }
  }

  /// Навигация к символу
  static void _navigateToSymbol(String symbol) {
    // Навигация реализована через NotificationService при нажатии на уведомление
    if (kDebugMode) {
      print(
          'Навигация к символу: $symbol (обрабатывается через NotificationService)');
    }
  }

  /// Подписка на топик
  static Future<void> subscribeToTopic(String topic) async {
    try {
      if (_messaging == null) return;

      await _messaging!.subscribeToTopic(topic);

      if (kDebugMode) {
        print('Подписка на топик: $topic');
      }
    } catch (e) {
      if (kDebugMode) {
        print('Ошибка подписки на топик $topic: $e');
      }
    }
  }

  /// Отписка от топика
  static Future<void> unsubscribeFromTopic(String topic) async {
    try {
      if (_messaging == null) return;

      await _messaging!.unsubscribeFromTopic(topic);

      if (kDebugMode) {
        print('Отписка от топика: $topic');
      }
    } catch (e) {
      if (kDebugMode) {
        print('Ошибка отписки от топика $topic: $e');
      }
    }
  }

  /// Очистка токена
  static Future<void> clearToken() async {
    try {
      if (_messaging == null) return;

      await _messaging!.deleteToken();
      _fcmToken = null;

      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('fcm_token');

      if (kDebugMode) {
        print('FCM токен очищен');
      }
    } catch (e) {
      if (kDebugMode) {
        print('Ошибка очистки FCM токена: $e');
      }
    }
  }
}

/// Обработчик сообщений в фоне (должен быть глобальной функцией)
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  await FirebaseService._firebaseMessagingBackgroundHandler(message);
}
