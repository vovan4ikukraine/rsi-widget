import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_service.dart';

/// Handles lightweight user/device identification for syncing alerts with backend.
class UserService {
  static const _userIdKey = 'user_id';
  static String? _userId;

  /// Ensure user id exists and device is registered with backend.
  static Future<String> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    _userId ??= prefs.getString(_userIdKey);

    if (_userId == null) {
      _userId = _generateUserId();
      await prefs.setString(_userIdKey, _userId!);
      if (kDebugMode) {
        debugPrint('UserService: generated new userId $_userId');
      }
    }

    FirebaseService.setUserId(_userId!);
    await FirebaseService.registerDeviceWithServer();
    return _userId!;
  }

  /// Returns existing user id, generating one if necessary.
  static Future<String> ensureUserId() async {
    return _userId ?? await initialize();
  }

  static String? get currentUserId => _userId;

  static String _generateUserId() {
    final random = Random.secure();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final randomPart = List<int>.generate(6, (_) => random.nextInt(36))
        .map((value) => value.toRadixString(36))
        .join();
    return 'user_${timestamp}_$randomPart';
  }
}


