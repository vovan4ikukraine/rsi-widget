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

/// Сервис для локальных уведомлений
class NotificationService {
  static final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  static bool _initialized = false;

  /// Инициализация сервиса уведомлений
  static Future<void> initialize() async {
    if (_initialized) return;

    try {
      // Настройки для Android
      const androidSettings =
          AndroidInitializationSettings('@mipmap/ic_launcher');

      // Настройки для iOS
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

      // Не запрашиваем разрешения автоматически при инициализации
      // Разрешения будут запрашиваться только когда они действительно нужны
      // if (Platform.isAndroid) {
      //   await _requestAndroidPermissions();
      // }

      _initialized = true;

      if (kDebugMode) {
        print('Сервис уведомлений инициализирован');
      }
    } catch (e) {
      if (kDebugMode) {
        print('Ошибка инициализации уведомлений: $e');
      }
    }
  }

  /// Запрос разрешений только при необходимости (например, при создании алерта)
  static Future<bool> requestPermissionsIfNeeded() async {
    try {
      final androidPlugin =
          _notifications.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();

      if (androidPlugin != null) {
        // Запрашиваем разрешение на уведомления только когда оно действительно нужно
        // Не запрашиваем разрешение на точные будильники автоматически,
        // так как это открывает настройки системы
        await androidPlugin.requestNotificationsPermission();
        return true;
      }
      return false;
    } catch (e) {
      if (kDebugMode) {
        print('Ошибка запроса разрешений Android: $e');
      }
      return false;
    }
  }

  /// Обработка нажатия на уведомление
  static void _onNotificationTapped(NotificationResponse response) {
    if (kDebugMode) {
      print('Нажато уведомление: ${response.payload}');
    }

    final payload = response.payload;
    if (payload != null) {
      _handleNotificationPayload(payload);
    }
  }

  /// Обработка payload уведомления
  static void _handleNotificationPayload(String payload) async {
    try {
      // Парсинг payload (может быть JSON строка или Map в виде строки)
      Map<String, dynamic>? data;

      // Пытаемся распарсить как JSON
      try {
        final decoded = json.decode(payload);
        if (decoded is Map<String, dynamic>) {
          data = decoded;
        }
      } catch (e) {
        // Если не JSON, пытаемся распарсить как строку формата "{key: value, ...}"
        if (payload.startsWith('{') && payload.endsWith('}')) {
          // Простой парсинг для формата FlutterLocalNotifications
          data = _parseSimpleMap(payload);
        }
      }

      if (data == null) {
        if (kDebugMode) {
          print('Не удалось распарсить payload: $payload');
        }
        return;
      }

      // Навигация на основе типа уведомления
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
        print('Навигация выполнена для payload: $data');
      }
    } catch (e) {
      if (kDebugMode) {
        print('Ошибка обработки payload: $e');
      }
    }
  }

  /// Простой парсинг строки формата Map
  static Map<String, dynamic>? _parseSimpleMap(String str) {
    try {
      // Убираем фигурные скобки
      final content = str.substring(1, str.length - 1);
      final Map<String, dynamic> result = {};

      // Простой парсинг ключ-значение
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

  /// Навигация к символу
  static Future<void> _navigateToSymbol(String symbol) async {
    try {
      final navigator = RSIWidgetApp.navigatorKey.currentState;
      if (navigator == null) return;

      // Получаем Isar из пути
      final dir = await getApplicationDocumentsDirectory();
      final isar = await Isar.open(
        [
          AlertRuleSchema,
          AlertStateSchema,
          AlertEventSchema,
          RsiDataSchema,
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
        print('Ошибка навигации к символу $symbol: $e');
      }
    }
  }

  /// Навигация к алерту
  static Future<void> _navigateToAlert(String alertId) async {
    try {
      final navigator = RSIWidgetApp.navigatorKey.currentState;
      if (navigator == null) return;

      // Получаем Isar из пути
      final dir = await getApplicationDocumentsDirectory();
      final isar = await Isar.open(
        [
          AlertRuleSchema,
          AlertStateSchema,
          AlertEventSchema,
          RsiDataSchema,
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
        print('Ошибка навигации к алерту $alertId: $e');
      }
    }
  }

  /// Показать RSI алерт
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
      final title = 'RSI Alert: $symbol';
      final body = message ?? 'RSI $rsi пересек уровень $level ($type)';

      const androidDetails = AndroidNotificationDetails(
        'rsi_alerts',
        'RSI Alerts',
        channelDescription: 'Уведомления о пересечении уровней RSI',
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
        print('Показано RSI уведомление для $symbol');
      }
    } catch (e) {
      if (kDebugMode) {
        print('Ошибка показа RSI уведомления: $e');
      }
    }
  }

  /// Показать общее уведомление
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
        channelDescription: 'Общие уведомления приложения',
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
        print('Ошибка показа уведомления: $e');
      }
    }
  }

  /// Показать уведомление о подключении к серверу
  static Future<void> showConnectionNotification({
    required bool connected,
    String? message,
  }) async {
    final title = connected ? 'Подключено к серверу' : 'Отключено от сервера';
    final body = message ??
        (connected
            ? 'Получение данных о RSI'
            : 'Проверьте подключение к интернету');

    await showNotification(
      title: title,
      body: body,
      payload: 'connection_${connected ? 'on' : 'off'}',
    );
  }

  /// Показать уведомление об ошибке
  static Future<void> showErrorNotification({
    required String error,
    String? details,
  }) async {
    await showNotification(
      title: 'Ошибка приложения',
      body: details ?? error,
      payload: 'error',
    );
  }

  /// Показать уведомление о синхронизации
  static Future<void> showSyncNotification({
    required String symbol,
    required bool success,
  }) async {
    final title = success ? 'Данные синхронизированы' : 'Ошибка синхронизации';
    final body = success
        ? 'RSI данные для $symbol обновлены'
        : 'Не удалось обновить данные для $symbol';

    await showNotification(
      title: title,
      body: body,
      payload: 'sync_${success ? 'success' : 'error'}_$symbol',
    );
  }

  /// Отменить все уведомления
  static Future<void> cancelAllNotifications() async {
    try {
      await _notifications.cancelAll();

      if (kDebugMode) {
        print('Все уведомления отменены');
      }
    } catch (e) {
      if (kDebugMode) {
        print('Ошибка отмены уведомлений: $e');
      }
    }
  }

  /// Отменить уведомления по ID
  static Future<void> cancelNotification(int id) async {
    try {
      await _notifications.cancel(id);
    } catch (e) {
      if (kDebugMode) {
        print('Ошибка отмены уведомления $id: $e');
      }
    }
  }

  /// Отменить уведомления по "тегу" (эмулируем через hashCode)
  static Future<void> cancelNotificationsByTag(String tag) async {
    try {
      // Генерируем ID из строки — одинаковый для одного тега
      final id = tag.hashCode.abs() % 1000000;
      await _notifications.cancel(id);
    } catch (e) {
      if (kDebugMode) {
        print('Ошибка отмены уведомлений по тегу $tag: $e');
      }
    }
  }

  /// Получить активные уведомления
  static Future<List<ActiveNotification>> getActiveNotifications() async {
    try {
      return await _notifications.getActiveNotifications();
    } catch (e) {
      if (kDebugMode) {
        print('Ошибка получения активных уведомлений: $e');
      }
      return [];
    }
  }

  /// Проверить, включены ли уведомления
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
      return true; // Для iOS предполагаем, что включены
    } catch (e) {
      if (kDebugMode) {
        print('Ошибка проверки статуса уведомлений: $e');
      }
      return false;
    }
  }

  /// Открыть настройки уведомлений
  static Future<void> openNotificationSettings() async {
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        await AppSettings.openAppSettings(
          type: AppSettingsType.notification,
        );
      } else {
        if (kDebugMode) {
          print('Открытие настроек поддерживается только на Android/iOS');
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('Ошибка открытия настроек уведомлений: $e');
      }
    }
  }
}
