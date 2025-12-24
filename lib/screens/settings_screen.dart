import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:isar/isar.dart';

import '../localization/app_localizations.dart';
import '../services/yahoo_proto.dart';
import '../services/auth_service.dart';
import '../services/alert_sync_service.dart';
import '../services/data_sync_service.dart';
import '../services/widget_service.dart';
import '../models/indicator_type.dart';
import '../state/app_state.dart';

class SettingsScreen extends StatefulWidget {
  final Isar? isar;

  const SettingsScreen({super.key, this.isar});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _notificationsEnabled = true;
  bool _soundEnabled = true;
  bool _vibrationEnabled = true;
  String _theme = 'dark';
  String _language = 'ru';
  IndicatorType _widgetIndicator = IndicatorType.rsi;
  StreamSubscription? _authSubscription;
  bool _isSignedIn = false;
  WidgetService? _widgetService;

  @override
  void initState() {
    super.initState();
    _isSignedIn = AuthService.isSignedIn;
    if (widget.isar != null) {
      _widgetService = WidgetService(
        isar: widget.isar!,
        yahooService: YahooProtoSource('https://rsi-workers.vovan4ikukraine.workers.dev'),
      );
    }
    _loadSettings();

    // Listen to auth state changes
    _authSubscription = AuthService.authStateChanges.listen((user) {
      if (mounted) {
        setState(() {
          _isSignedIn = user != null;
        });
      }
    });
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final savedWidgetIndicator = prefs.getString('rsi_widget_indicator');
    setState(() {
      _notificationsEnabled = prefs.getBool('notifications_enabled') ?? true;
      _soundEnabled = prefs.getBool('sound_enabled') ?? true;
      _vibrationEnabled = prefs.getBool('vibration_enabled') ?? true;
      _theme = prefs.getString('theme') ?? 'dark';
      _language = prefs.getString('language') ?? 'ru';
      _widgetIndicator = savedWidgetIndicator != null
          ? IndicatorType.fromJson(savedWidgetIndicator)
          : IndicatorType.rsi;
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('notifications_enabled', _notificationsEnabled);
    await prefs.setBool('sound_enabled', _soundEnabled);
    await prefs.setBool('vibration_enabled', _vibrationEnabled);
    await prefs.setString('theme', _theme);
    await prefs.setString('language', _language);
    await prefs.setString('rsi_widget_indicator', _widgetIndicator.toJson());
  }

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final appState = AppStateScope.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(loc.t('settings_title')),
        backgroundColor: Colors.blue[900],
        foregroundColor: Colors.white,
      ),
      body: ListView(
        children: [
          // Notifications
          _buildSectionCard(
            title: loc.t('settings_notifications_title'),
            icon: Icons.notifications,
            children: [
              SwitchListTile(
                title: Text(loc.t('settings_enable_notifications')),
                subtitle: Text(loc.t('settings_enable_notifications_sub')),
                value: _notificationsEnabled,
                onChanged: (value) {
                  setState(() {
                    _notificationsEnabled = value;
                  });
                  _saveSettings();
                },
              ),
              SwitchListTile(
                title: Text(loc.t('settings_sound')),
                subtitle: Text(loc.t('settings_sound_sub')),
                value: _soundEnabled,
                onChanged: _notificationsEnabled
                    ? (value) {
                        setState(() {
                          _soundEnabled = value;
                        });
                        _saveSettings();
                      }
                    : null,
              ),
              SwitchListTile(
                title: Text(loc.t('settings_vibration')),
                subtitle: Text(loc.t('settings_vibration_sub')),
                value: _vibrationEnabled,
                onChanged: _notificationsEnabled
                    ? (value) {
                        setState(() {
                          _vibrationEnabled = value;
                        });
                        _saveSettings();
                      }
                    : null,
              ),
            ],
          ),

          // Appearance
          _buildSectionCard(
            title: loc.t('settings_appearance_title'),
            icon: Icons.palette,
            children: [
              ListTile(
                title: Text(loc.t('settings_theme')),
                subtitle: Text(_theme == 'dark'
                    ? loc.t('settings_theme_dark')
                    : loc.t('settings_theme_light')),
                trailing: const Icon(Icons.arrow_forward_ios),
                onTap: () => _showThemeDialog(appState),
              ),
              ListTile(
                title: Text(loc.t('settings_language')),
                subtitle: Text(_language == 'ru'
                    ? loc.t('settings_language_russian')
                    : loc.t('settings_language_english')),
                trailing: const Icon(Icons.arrow_forward_ios),
                onTap: () => _showLanguageDialog(appState),
              ),
            ],
          ),

          // Widget
          _buildSectionCard(
            title: 'Widget Settings',
            icon: Icons.widgets,
            children: [
              ListTile(
                title: const Text('Widget Indicator'),
                subtitle: Text(_widgetIndicator.displayName),
                trailing: const Icon(Icons.arrow_forward_ios),
                onTap: widget.isar != null ? () => _showWidgetIndicatorDialog(loc) : null,
              ),
            ],
          ),

          // Data
          _buildSectionCard(
            title: loc.t('settings_data_title'),
            icon: Icons.data_usage,
            children: [
              ListTile(
                title: Text(loc.t('settings_clear_cache')),
                subtitle: Text(loc.t('settings_clear_cache_sub')),
                trailing: const Icon(Icons.delete),
                onTap: () => _showClearCacheDialog(loc),
              ),
            ],
          ),

          // Account
          _buildSectionCard(
            title: loc.t('settings_account_title'),
            icon: Icons.person,
            children: [
              if (_isSignedIn) ...[
                ListTile(
                  leading: CircleAvatar(
                    backgroundImage: AuthService.photoUrl != null
                        ? NetworkImage(AuthService.photoUrl!)
                        : null,
                    child: AuthService.photoUrl == null
                        ? Icon(Icons.person)
                        : null,
                  ),
                  title: Text(
                      AuthService.displayName ?? AuthService.email ?? 'User'),
                  subtitle: Text(
                    AuthService.email ?? '',
                  ),
                ),
                const Divider(),
                ListTile(
                  title: Text(loc.t('settings_profile')),
                  subtitle: Text(loc.t('settings_profile_sub')),
                  trailing: const Icon(Icons.arrow_forward_ios),
                  onTap: () => _showProfileDialog(loc),
                ),
                ListTile(
                  title: Text(loc.t('settings_sync')),
                  subtitle: Text(loc.t('settings_sync_sub')),
                  trailing: const Icon(Icons.sync),
                  onTap: () => _showSyncDialog(loc),
                ),
                const Divider(),
                ListTile(
                  title: Text(
                    loc.t('auth_sign_out'),
                    style: TextStyle(color: Colors.red[700]),
                  ),
                  trailing: const Icon(Icons.logout, color: Colors.red),
                  onTap: () => _showSignOutDialog(loc),
                ),
              ] else ...[
                ListTile(
                  title: Text(loc.t('auth_sign_in_google')),
                  subtitle: Text(loc.t('auth_subtitle')),
                  leading: const Icon(Icons.login, color: Colors.blue),
                  trailing: const Icon(Icons.arrow_forward_ios),
                  onTap: () => _signInFromSettings(loc),
                ),
              ],
            ],
          ),

          // About
          _buildSectionCard(
            title: loc.t('settings_about_title'),
            icon: Icons.info,
            children: [
              ListTile(
                title: Text(loc.t('settings_version')),
                subtitle: const Text('1.0.0'),
                trailing: const Icon(Icons.arrow_forward_ios),
                onTap: () => _showVersionDialog(loc),
              ),
              ListTile(
                title: Text(loc.t('settings_license')),
                subtitle: Text(loc.t('settings_license_sub')),
                trailing: const Icon(Icons.arrow_forward_ios),
                onTap: () => _showLicenseDialog(loc),
              ),
              ListTile(
                title: Text(loc.t('settings_support')),
                subtitle: Text(loc.t('settings_support_sub')),
                trailing: const Icon(Icons.arrow_forward_ios),
                onTap: () => _showSupportDialog(loc),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSectionCard({
    required String title,
    required IconData icon,
    required List<Widget> children,
  }) {
    return Card(
      margin: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(icon, color: Colors.blue[700]),
                const SizedBox(width: 12),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          ...children,
        ],
      ),
    );
  }

  void _showThemeDialog(AppState appState) {
    final loc = context.loc;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(loc.t('settings_select_theme')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(loc.t('settings_theme_dark')),
              leading: Radio<String>(
                value: 'dark',
                groupValue: _theme,
                onChanged: (value) async {
                  if (value == null) return;
                  setState(() {
                    _theme = value;
                  });
                  await appState.setTheme(value);
                  await _saveSettings();
                  Navigator.pop(context);
                },
              ),
            ),
            ListTile(
              title: Text(loc.t('settings_theme_light')),
              leading: Radio<String>(
                value: 'light',
                groupValue: _theme,
                onChanged: (value) async {
                  if (value == null) return;
                  setState(() {
                    _theme = value;
                  });
                  await appState.setTheme(value);
                  await _saveSettings();
                  Navigator.pop(context);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showLanguageDialog(AppState appState) {
    final loc = context.loc;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(loc.t('settings_select_language')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(loc.t('settings_language_russian')),
              leading: Radio<String>(
                value: 'ru',
                groupValue: _language,
                onChanged: (value) async {
                  if (value == null) return;
                  setState(() {
                    _language = value;
                  });
                  await appState.setLanguage(value);
                  await _saveSettings();
                  Navigator.pop(context);
                },
              ),
            ),
            ListTile(
              title: Text(loc.t('settings_language_english')),
              leading: Radio<String>(
                value: 'en',
                groupValue: _language,
                onChanged: (value) async {
                  if (value == null) return;
                  setState(() {
                    _language = value;
                  });
                  await appState.setLanguage(value);
                  await _saveSettings();
                  Navigator.pop(context);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showClearCacheDialog(AppLocalizations loc) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(loc.t('settings_clear_cache_title')),
        content: Text(loc.t('settings_clear_cache_confirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(loc.t('settings_cancel')),
          ),
          ElevatedButton(
            onPressed: () async {
              // Clear data cache
              DataCache.clear();
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(loc.t('settings_clear_cache_success'))),
              );
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: Text(loc.t('settings_clear_cache')),
          ),
        ],
      ),
    );
  }

  void _showProfileDialog(AppLocalizations loc) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(loc.t('settings_profile_dialog_title')),
        content: Text(loc.t('settings_profile_dialog_message')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(loc.t('settings_ok')),
          ),
        ],
      ),
    );
  }

  void _showSyncDialog(AppLocalizations loc) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(loc.t('settings_sync_dialog_title')),
        content: Text(loc.t('settings_sync_dialog_message')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(loc.t('settings_ok')),
          ),
        ],
      ),
    );
  }

  void _showVersionDialog(AppLocalizations loc) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(loc.t('settings_about_dialog_title')),
        content: Text(loc.t('settings_about_dialog_body')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(loc.t('settings_ok')),
          ),
        ],
      ),
    );
  }

  void _showLicenseDialog(AppLocalizations loc) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(loc.t('settings_license_dialog_title')),
        content: SingleChildScrollView(
          child: Text(loc.t('settings_license_dialog_message')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(loc.t('settings_ok')),
          ),
        ],
      ),
    );
  }

  void _showWidgetIndicatorDialog(AppLocalizations loc) async {
    if (widget.isar == null) return;
    
    final prefs = await SharedPreferences.getInstance();
    final savedTimeframe = prefs.getString('rsi_widget_timeframe') ?? '15m';
    final savedSortDescending = prefs.getBool('rsi_widget_sort_descending') ?? true;
    final savedStochDPeriod = prefs.getInt('watchlist_stoch_d_period') ?? 3;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Select Widget Indicator'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: IndicatorType.values.map((indicator) {
            return ListTile(
              title: Text(indicator.displayName),
              leading: Radio<IndicatorType>(
                value: indicator,
                groupValue: _widgetIndicator,
                onChanged: (value) async {
                  if (value == null) return;
                  setState(() {
                    _widgetIndicator = value;
                  });
                  await _saveSettings();
                  Navigator.pop(context);
                  
                  // Update widget with new indicator
                  if (_widgetService != null) {
                    // Get period for the selected indicator
                    final indicatorPeriod = prefs.getInt('watchlist_${value.toJson()}_period') ?? 
                                           prefs.getInt('home_${value.toJson()}_period') ?? 
                                           value.defaultPeriod;
                    final indicatorParams = value == IndicatorType.stoch
                        ? {'dPeriod': savedStochDPeriod}
                        : null;
                    await _widgetService!.updateWidget(
                      timeframe: savedTimeframe,
                      rsiPeriod: indicatorPeriod,
                      sortDescending: savedSortDescending,
                      indicator: value,
                      indicatorParams: indicatorParams,
                    );
                  }
                  
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: const Text('Widget indicator updated'),
                        backgroundColor: Colors.green,
                      ),
                    );
                  }
                },
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  void _showSupportDialog(AppLocalizations loc) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(loc.t('settings_support_dialog_title')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(loc.t('settings_support_email')),
            SizedBox(height: 8),
            Text(loc.t('settings_support_telegram')),
            SizedBox(height: 8),
            Text(loc.t('settings_support_github')),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(loc.t('settings_ok')),
          ),
        ],
      ),
    );
  }

  Future<void> _signInFromSettings(AppLocalizations loc) async {
    try {
      // Save anonymous watchlist and alerts to cache before signing in
      if (widget.isar != null) {
        await DataSyncService.saveWatchlistToCache(widget.isar!);
        await DataSyncService.saveAlertsToCache(widget.isar!);
      }

      await AuthService.signInWithGoogle();

      // Sync data after sign in
      if (widget.isar != null) {
        unawaited(AlertSyncService.fetchAndSyncAlerts(widget.isar!));
        unawaited(AlertSyncService.syncPendingAlerts(widget.isar!));
        unawaited(DataSyncService.fetchWatchlist(widget.isar!));
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(loc.t('auth_signed_in_as',
                params: {'email': AuthService.email ?? 'User'})),
            backgroundColor: Colors.green,
          ),
        );
        // Refresh the screen to show account info
        setState(() {});
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(loc.t('auth_error_message')),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _showSignOutDialog(AppLocalizations loc) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(loc.t('auth_sign_out')),
        content: const Text('Are you sure you want to sign out?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(loc.t('settings_cancel')),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context); // Close dialog first
              try {
                await AuthService.signOut(isar: widget.isar);
                // UI will update automatically via authStateChanges listener
                // No need to pop - let user see the updated state
              } catch (e) {
                // Show error only if context is still valid
                if (mounted && context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Error signing out: $e'),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: Text(loc.t('auth_sign_out')),
          ),
        ],
      ),
    );
  }
}
