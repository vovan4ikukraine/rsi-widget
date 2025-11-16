import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../localization/app_localizations.dart';
import '../services/yahoo_proto.dart';
import '../state/app_state.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _notificationsEnabled = true;
  bool _soundEnabled = true;
  bool _vibrationEnabled = true;
  String _theme = 'dark';
  String _language = 'ru';

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _notificationsEnabled = prefs.getBool('notifications_enabled') ?? true;
      _soundEnabled = prefs.getBool('sound_enabled') ?? true;
      _vibrationEnabled = prefs.getBool('vibration_enabled') ?? true;
      _theme = prefs.getString('theme') ?? 'dark';
      _language = prefs.getString('language') ?? 'ru';
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('notifications_enabled', _notificationsEnabled);
    await prefs.setBool('sound_enabled', _soundEnabled);
    await prefs.setBool('vibration_enabled', _vibrationEnabled);
    await prefs.setString('theme', _theme);
    await prefs.setString('language', _language);
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
}
