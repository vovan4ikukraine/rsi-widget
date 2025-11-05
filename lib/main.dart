import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:isar/isar.dart';
import 'package:path_provider/path_provider.dart';
import 'package:rsi_widget/models.dart';
import 'package:rsi_widget/services/notification_service.dart';
import 'package:rsi_widget/services/firebase_service.dart';
import 'package:rsi_widget/screens/home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1️⃣ Инициализация Firebase
  await Firebase.initializeApp();

  // 2️⃣ Получаем путь для локальной базы (Isar требует directory)
  final dir = await getApplicationDocumentsDirectory();

  // 3️⃣ Инициализация Isar
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

  // 4️⃣ Инициализация сервисов
  await NotificationService.initialize();
  await FirebaseService.initialize();

  // 5️⃣ Запуск приложения
  runApp(RSIWidgetApp(isar: isar));
}

class RSIWidgetApp extends StatelessWidget {
  final Isar isar;
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  const RSIWidgetApp({super.key, required this.isar});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RSI Widget',
      navigatorKey: navigatorKey,
      theme: ThemeData(
        primarySwatch: Colors.blue,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: HomeScreen(isar: isar),
      debugShowCheckedModeBanner: false,
    );
  }
}
