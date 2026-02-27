import 'dart:async';
import 'package:flutter/material.dart';
import 'package:isar_db/isar_db.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/app_config.dart';
import '../localization/app_localizations.dart';
import '../services/yahoo_proto.dart';
import '../services/auth_service.dart';
import '../services/alert_sync_service.dart';
import '../services/data_sync_service.dart';
import '../services/widget_service.dart';
import '../models/indicator_type.dart';
import '../state/app_state.dart';
import '../utils/context_extensions.dart';
import '../utils/preferences_storage.dart';

class SettingsScreen extends StatefulWidget {
  final Isar? isar;

  const SettingsScreen({super.key, this.isar});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _theme = 'system';
  String _language = 'ru';
  IndicatorType _widgetIndicator = IndicatorType.rsi;
  StreamSubscription? _authSubscription;
  bool _isSignedIn = false;
  late final WidgetService _widgetService;

  @override
  void initState() {
    super.initState();
    _isSignedIn = AuthService.isSignedIn;
    _widgetService = WidgetService(
      yahooService: YahooProtoSource(AppConfig.apiBaseUrl),
    );
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
    final prefs = await PreferencesStorage.instance;
    // Use 'widget_indicator' to match Android native code and widget_service.dart
    final savedWidgetIndicator = prefs.getString('widget_indicator');
    setState(() {
      _theme = prefs.getString('theme') ?? 'system';
      _language = prefs.getString('language') ?? 'ru';
      _widgetIndicator = savedWidgetIndicator != null
          ? IndicatorType.fromJson(savedWidgetIndicator)
          : IndicatorType.rsi;
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await PreferencesStorage.instance;
    await prefs.setString('theme', _theme);
    await prefs.setString('language', _language);
    // Use 'widget_indicator' to match Android native code and widget_service.dart
    await prefs.setString('widget_indicator', _widgetIndicator.toJson());
  }

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final appState = AppStateScope.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(loc.t('settings_title')),
        titleSpacing: 8, // Reduce spacing between back button and title
        backgroundColor: Colors.blue[900],
        foregroundColor: Colors.white,
      ),
      body: ListView(
        children: [
          // Appearance
          _buildSectionCard(
            title: loc.t('settings_appearance_title'),
            icon: Icons.palette,
            children: [
              ListTile(
                title: Text(loc.t('settings_theme')),
                subtitle: Text(loc.t(_themeDisplayKey(_theme))),
                trailing: const Icon(Icons.arrow_forward_ios),
                onTap: () => _showThemeDialog(appState),
              ),
              ListTile(
                title: Text(loc.t('settings_language')),
                subtitle: Text(loc.t(_languageDisplayKey(_language))),
                trailing: const Icon(Icons.arrow_forward_ios),
                onTap: () => _showLanguageDialog(appState),
              ),
            ],
          ),

          // Widget
          _buildSectionCard(
            title: loc.t('settings_widget_title'),
            icon: Icons.widgets,
            children: [
              ListTile(
                title: Text(loc.t('settings_widget_indicator')),
                subtitle: Text(_widgetIndicator.displayName),
                trailing: const Icon(Icons.arrow_forward_ios),
                onTap: widget.isar != null ? () => _showWidgetIndicatorDialog(loc) : null,
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
                        ? const Icon(Icons.person)
                        : null,
                  ),
                  title: Text(
                      AuthService.displayName ?? AuthService.email ?? loc.t('common_user')),
                  subtitle: Text(
                    AuthService.email ?? '',
                  ),
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
                title: Text(loc.t('settings_privacy_policy')),
                subtitle: Text(loc.t('settings_privacy_policy_sub')),
                leading: const Icon(Icons.privacy_tip_outlined),
                trailing: const Icon(Icons.arrow_forward_ios),
                onTap: () => _launchPrivacyPolicy(loc),
              ),
              ListTile(
                title: Text(loc.t('settings_support')),
                subtitle: Text(loc.t('settings_support_sub')),
                leading: const Icon(Icons.email_outlined),
                trailing: const Icon(Icons.arrow_forward_ios),
                onTap: () => _launchSupportEmail(loc),
              ),
              // TODO: Uncomment when Telegram group is ready
              // ListTile(
              //   title: Text(loc.t('settings_telegram_group')),
              //   subtitle: Text(loc.t('settings_telegram_group_sub')),
              //   leading: const Icon(Icons.groups_outlined),
              //   trailing: const Icon(Icons.arrow_forward_ios),
              //   onTap: () => _launchTelegramGroup(loc),
              // ),
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

  static String _themeDisplayKey(String theme) {
    switch (theme) {
      case 'dark':
        return 'settings_theme_dark';
      case 'light':
        return 'settings_theme_light';
      default:
        return 'settings_theme_system';
    }
  }

  void _showThemeDialog(AppState appState) {
    final loc = context.loc;

    Future<void> selectTheme(String value) async {
      if (value.isEmpty) return;
      final navigator = Navigator.of(context);
      setState(() {
        _theme = value;
      });
      await appState.setTheme(value);
      await _saveSettings();
      if (mounted) {
        navigator.pop();
      }
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(loc.t('settings_select_theme')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(loc.t('settings_theme_system')),
              leading: Radio<String>(
                value: 'system',
                groupValue: _theme,
                onChanged: (v) => selectTheme(v ?? ''),
              ),
            ),
            ListTile(
              title: Text(loc.t('settings_theme_dark')),
              leading: Radio<String>(
                value: 'dark',
                groupValue: _theme,
                onChanged: (v) => selectTheme(v ?? ''),
              ),
            ),
            ListTile(
              title: Text(loc.t('settings_theme_light')),
              leading: Radio<String>(
                value: 'light',
                groupValue: _theme,
                onChanged: (v) => selectTheme(v ?? ''),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _languageDisplayKey(String code) {
    switch (code) {
      case 'ru':
        return 'settings_language_russian';
      case 'uk':
        return 'settings_language_ukrainian';
      case 'es':
        return 'settings_language_spanish';
      case 'pt':
        return 'settings_language_portuguese';
      case 'de':
        return 'settings_language_german';
      case 'fr':
        return 'settings_language_french';
      case 'tr':
        return 'settings_language_turkish';
      case 'id':
        return 'settings_language_indonesian';
      case 'vi':
        return 'settings_language_vietnamese';
      case 'fil':
        return 'settings_language_filipino';
      default:
        return 'settings_language_english';
    }
  }

  void _showLanguageDialog(AppState appState) {
    final loc = context.loc;

    Future<void> selectLanguage(String value) async {
      if (value.isEmpty) return;
      final navigator = Navigator.of(context);
      setState(() {
        _language = value;
      });
      await appState.setLanguage(value);
      await _saveSettings();
      if (mounted) {
        navigator.pop();
      }
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(loc.t('settings_select_language')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(loc.t('settings_language_english')),
                leading: Radio<String>(
                  value: 'en',
                  groupValue: _language,
                  onChanged: (v) => selectLanguage(v ?? ''),
                ),
              ),
              ListTile(
                title: Text(loc.t('settings_language_russian')),
                leading: Radio<String>(
                  value: 'ru',
                  groupValue: _language,
                  onChanged: (v) => selectLanguage(v ?? ''),
                ),
              ),
              ListTile(
                title: Text(loc.t('settings_language_ukrainian')),
                leading: Radio<String>(
                  value: 'uk',
                  groupValue: _language,
                  onChanged: (v) => selectLanguage(v ?? ''),
                ),
              ),
              ListTile(
                title: Text(loc.t('settings_language_spanish')),
                leading: Radio<String>(
                  value: 'es',
                  groupValue: _language,
                  onChanged: (v) => selectLanguage(v ?? ''),
                ),
              ),
              ListTile(
                title: Text(loc.t('settings_language_portuguese')),
                leading: Radio<String>(
                  value: 'pt',
                  groupValue: _language,
                  onChanged: (v) => selectLanguage(v ?? ''),
                ),
              ),
              ListTile(
                title: Text(loc.t('settings_language_german')),
                leading: Radio<String>(
                  value: 'de',
                  groupValue: _language,
                  onChanged: (v) => selectLanguage(v ?? ''),
                ),
              ),
              ListTile(
                title: Text(loc.t('settings_language_french')),
                leading: Radio<String>(
                  value: 'fr',
                  groupValue: _language,
                  onChanged: (v) => selectLanguage(v ?? ''),
                ),
              ),
              ListTile(
                title: Text(loc.t('settings_language_turkish')),
                leading: Radio<String>(
                  value: 'tr',
                  groupValue: _language,
                  onChanged: (v) => selectLanguage(v ?? ''),
                ),
              ),
              ListTile(
                title: Text(loc.t('settings_language_indonesian')),
                leading: Radio<String>(
                  value: 'id',
                  groupValue: _language,
                  onChanged: (v) => selectLanguage(v ?? ''),
                ),
              ),
              ListTile(
                title: Text(loc.t('settings_language_vietnamese')),
                leading: Radio<String>(
                  value: 'vi',
                  groupValue: _language,
                  onChanged: (v) => selectLanguage(v ?? ''),
                ),
              ),
              ListTile(
                title: Text(loc.t('settings_language_filipino')),
                leading: Radio<String>(
                  value: 'fil',
                  groupValue: _language,
                  onChanged: (v) => selectLanguage(v ?? ''),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showWidgetIndicatorDialog(AppLocalizations loc) async {
    if (widget.isar == null) return;

    final buildContext = context;
    final prefs = await PreferencesStorage.instance;
    final savedSortDescending = prefs.getBool('rsi_widget_sort_descending') ?? false; // Default: ascending

    if (!mounted) return;
    showDialog(
      context: buildContext,
      builder: (overlayContext) => AlertDialog(
        title: Text(loc.t('settings_widget_indicator_select')),
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
                  final navigator = Navigator.of(overlayContext);
                  setState(() {
                    _widgetIndicator = value;
                  });
                  await _saveSettings();
                  if (mounted) {
                    navigator.pop();
                  }
                  
                  // Update widget with new indicator
                  {
                    // Get current settings for the selected indicator from watchlist/home
                    // This ensures widget uses actual user settings, not defaults
                    final indicatorKey = value.toJson();
                    
                    // Get timeframe: try watchlist first, then home, then widget saved, then default
                    final watchlistTimeframe = prefs.getString('watchlist_timeframe');
                    final homeTimeframe = prefs.getString('home_selected_timeframe');
                    final widgetTimeframe = prefs.getString('rsi_widget_timeframe');
                    final indicatorTimeframe = watchlistTimeframe ??
                                              homeTimeframe ??
                                              widgetTimeframe ??
                                              '15m';
                    
                    // Get period: try watchlist first, then home, then default
                    final watchlistPeriod = prefs.getInt('watchlist_${indicatorKey}_period');
                    final homePeriod = prefs.getInt('home_${indicatorKey}_period');
                    final indicatorPeriod = watchlistPeriod ?? 
                                           homePeriod ?? 
                                           value.defaultPeriod;
                    
                    // For STOCH, get %D period: try watchlist first, then home, then default
                    Map<String, dynamic>? indicatorParams;
                    if (value == IndicatorType.stoch) {
                      final watchlistStochD = prefs.getInt('watchlist_stoch_d_period');
                      final homeStochD = prefs.getInt('home_stoch_d_period');
                      final stochDPeriod = watchlistStochD ?? homeStochD ?? 3;
                      indicatorParams = {'dPeriod': stochDPeriod};
                      
                      // DEBUG: Log STOCH parameters
                      debugPrint('SettingsScreen: Updating widget with STOCH - period (K): $indicatorPeriod, dPeriod (D): $stochDPeriod');
                      debugPrint('SettingsScreen: watchlist_stoch_d_period=$watchlistStochD, home_stoch_d_period=$homeStochD');
                    }
                    
                    // DEBUG: Log parameters being used
                    debugPrint('SettingsScreen: Updating widget with indicator=$indicatorKey, timeframe=$indicatorTimeframe (watchlist=$watchlistTimeframe, home=$homeTimeframe), period=$indicatorPeriod (watchlist=$watchlistPeriod, home=$homePeriod)');
                    
                    await _widgetService.updateWidget(
                      timeframe: indicatorTimeframe,
                      rsiPeriod: indicatorPeriod,
                      sortDescending: savedSortDescending,
                      indicator: value,
                      indicatorParams: indicatorParams,
                    );
                  }
                  
                  if (overlayContext.mounted) {
                    overlayContext.showSuccess(loc.t('settings_widget_indicator_updated'));
                  }
                },
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  static const String _privacyPolicyUrl =
      'https://vovan4ikukraine.github.io/indi-charts-public/privacy.html';

  Future<void> _launchPrivacyPolicy(AppLocalizations loc) async {
    final uri = Uri.parse(_privacyPolicyUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      if (mounted) {
        context.showError(loc.t('settings_launch_link_error'));
      }
    }
  }

  Future<void> _launchSupportEmail(AppLocalizations loc) async {
    final uri = Uri.parse('mailto:ads.contact.manager@gmail.com');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      if (mounted) {
        context.showError(loc.t('settings_launch_email_error'));
      }
    }
  }

  // TODO: Uncomment when Telegram group is ready
  // Future<void> _launchTelegramGroup(AppLocalizations loc) async {
  //   const url = 'https://t.me/+KdhTzvHT5YY3ZTFk';
  //   final uri = Uri.parse(url);
  //   if (await canLaunchUrl(uri)) {
  //     await launchUrl(uri, mode: LaunchMode.externalApplication);
  //   } else {
  //     if (mounted) {
  //       context.showError(loc.t('settings_launch_link_error'));
  //     }
  //   }
  // }

  Future<void> _signInFromSettings(AppLocalizations loc) async {
    try {
      // Save anonymous watchlist and alerts to cache before signing in
      await DataSyncService.saveWatchlistToCache();
      await DataSyncService.saveAlertsToCache();

      await AuthService.signInWithGoogle();

      unawaited(AlertSyncService.fetchAndSyncAlerts());
      unawaited(AlertSyncService.syncPendingAlerts());
      unawaited(DataSyncService.fetchWatchlist());

      if (mounted) {
        context.showSuccess(
          loc.t('auth_signed_in_as',
              params: {'email': AuthService.email ?? loc.t('common_user')}),
        );
        // Refresh the screen to show account info
        setState(() {});
      }
    } catch (e) {
      if (mounted) {
        context.showError(loc.t('auth_error_message'));
      }
    }
  }

  void _showSignOutDialog(AppLocalizations loc) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(loc.t('auth_sign_out')),
            content: Text(loc.t('auth_sign_out_confirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(loc.t('settings_cancel')),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context); // Close dialog first
              try {
                await AuthService.signOut();
                // UI will update automatically via authStateChanges listener
                // No need to pop - let user see the updated state
              } catch (e) {
                // Show error only if context is still valid
                if (mounted && context.mounted) {
                  context.showError(
                    loc.t('auth_sign_out_error', params: {'error': e.toString()}),
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
