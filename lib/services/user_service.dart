import 'dart:async' show unawaited;
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'firebase_service.dart';

/// Handles lightweight user/device identification for syncing alerts with backend.
class UserService {
  static const _userIdKey = 'user_id';
  static const _firebaseUserIdKey = 'firebase_user_id';
  static String? _userId;
  static String? _firebaseUserId;

  /// Ensure user id exists and device is registered with backend.
  /// Uses Firebase UID if available, otherwise generates temporary ID.
  static Future<String> initialize() async {
    final prefs = await SharedPreferences.getInstance();

    // Check if user is signed in with Firebase
    final firebaseUser = FirebaseAuth.instance.currentUser;
    if (firebaseUser != null) {
      _firebaseUserId = firebaseUser.uid;
      await prefs.setString(_firebaseUserIdKey, _firebaseUserId!);
      _userId = _firebaseUserId;
      if (kDebugMode) {
        debugPrint('UserService: using Firebase UID $_userId');
      }
    } else {
      // Check if we have saved Firebase UID (for migration)
      _firebaseUserId = prefs.getString(_firebaseUserIdKey);
      if (_firebaseUserId != null) {
        _userId = _firebaseUserId;
        if (kDebugMode) {
          debugPrint('UserService: using saved Firebase UID $_userId');
        }
      } else {
        // Generate temporary ID
        _userId ??= prefs.getString(_userIdKey);
        if (_userId == null) {
          _userId = _generateUserId();
          await prefs.setString(_userIdKey, _userId!);
          if (kDebugMode) {
            debugPrint('UserService: generated new temporary userId $_userId');
          }
        }
      }
    }

    FirebaseService.setUserId(_userId!);
    // Don't block initialization - register device in background
    unawaited(FirebaseService.registerDeviceWithServer());
    return _userId!;
  }

  /// Set Firebase user ID (called after successful authentication)
  static Future<void> setFirebaseUserId(String firebaseUid) async {
    final prefs = await SharedPreferences.getInstance();
    _firebaseUserId = firebaseUid;
    _userId = firebaseUid;
    await prefs.setString(_firebaseUserIdKey, firebaseUid);
    await prefs.setString(_userIdKey, firebaseUid);

    FirebaseService.setUserId(firebaseUid);
    await FirebaseService.registerDeviceWithServer();

    if (kDebugMode) {
      debugPrint('UserService: set Firebase UID $_userId');
    }
  }

  /// Clear Firebase user ID (called on sign out)
  static Future<void> clearFirebaseUserId() async {
    final prefs = await SharedPreferences.getInstance();
    _firebaseUserId = null;

    // Generate new temporary ID
    _userId = _generateUserId();
    await prefs.setString(_userIdKey, _userId!);
    await prefs.remove(_firebaseUserIdKey);

    FirebaseService.setUserId(_userId!);
    await FirebaseService.registerDeviceWithServer();

    if (kDebugMode) {
      debugPrint(
          'UserService: cleared Firebase UID, generated new temporary ID $_userId');
    }
  }

  /// Returns existing user id, generating one if necessary.
  static Future<String> ensureUserId() async {
    return _userId ?? await initialize();
  }

  static String? get currentUserId => _userId;

  /// Check if user is authenticated with Firebase
  static bool get isAuthenticated => _firebaseUserId != null;

  static String _generateUserId() {
    final random = Random.secure();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final randomPart = List<int>.generate(6, (_) => random.nextInt(36))
        .map((value) => value.toRadixString(36))
        .join();
    return 'user_${timestamp}_$randomPart';
  }
}
