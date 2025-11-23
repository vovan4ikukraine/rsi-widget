import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/indicator_type.dart';

class AppState extends ChangeNotifier {
  AppState({
    required Locale locale,
    required ThemeMode themeMode,
  })  : _locale = locale,
        _themeMode = themeMode {
    _loadSelectedIndicator();
  }

  static const _languageKey = 'language';
  static const _themeKey = 'theme';
  static const _selectedIndicatorKey = 'selected_indicator';

  Locale _locale;
  ThemeMode _themeMode;
  IndicatorType _selectedIndicator = IndicatorType.rsi;

  Locale get locale => _locale;
  ThemeMode get themeMode => _themeMode;
  IndicatorType get selectedIndicator => _selectedIndicator;

  Future<void> setLanguage(String languageCode) async {
    if (languageCode == _locale.languageCode) return;

    _locale = Locale(languageCode);
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_languageKey, languageCode);
  }

  Future<void> setTheme(String theme) async {
    final newThemeMode = theme == 'light' ? ThemeMode.light : ThemeMode.dark;

    if (newThemeMode == _themeMode) return;

    _themeMode = newThemeMode;
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeKey, theme);
  }

  Future<void> setIndicator(IndicatorType indicator) async {
    if (_selectedIndicator == indicator) return;

    _selectedIndicator = indicator;
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_selectedIndicatorKey, indicator.toJson());
  }

  void _loadSelectedIndicator() {
    SharedPreferences.getInstance().then((prefs) {
      final saved = prefs.getString(_selectedIndicatorKey);
      if (saved != null) {
        try {
          _selectedIndicator = IndicatorType.fromJson(saved);
          notifyListeners();
        } catch (e) {
          // Invalid value, use default
        }
      }
    });
  }
}

class AppStateScope extends InheritedNotifier<AppState> {
  const AppStateScope({
    super.key,
    required AppState notifier,
    required super.child,
  }) : super(notifier: notifier);

  static AppState of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppStateScope>();
    assert(scope != null, 'AppStateScope not found in context');
    return scope!.notifier!;
  }
}
