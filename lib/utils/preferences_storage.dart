import 'package:shared_preferences/shared_preferences.dart';

/// Centralized access to SharedPreferences.
/// Use instead of SharedPreferences.getInstance() for consistency and testability.
abstract final class PreferencesStorage {
  static Future<SharedPreferences> get instance =>
      SharedPreferences.getInstance();
}
