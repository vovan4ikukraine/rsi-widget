import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/yahoo_proto.dart';

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
  bool _autoRefresh = true;
  int _refreshInterval = 60; // секунды

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
      _autoRefresh = prefs.getBool('auto_refresh') ?? true;
      _refreshInterval = prefs.getInt('refresh_interval') ?? 60;
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('notifications_enabled', _notificationsEnabled);
    await prefs.setBool('sound_enabled', _soundEnabled);
    await prefs.setBool('vibration_enabled', _vibrationEnabled);
    await prefs.setString('theme', _theme);
    await prefs.setString('language', _language);
    await prefs.setBool('auto_refresh', _autoRefresh);
    await prefs.setInt('refresh_interval', _refreshInterval);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Настройки'),
        backgroundColor: Colors.blue[900],
        foregroundColor: Colors.white,
      ),
      body: ListView(
        children: [
          // Уведомления
          _buildSectionCard(
            title: 'Уведомления',
            icon: Icons.notifications,
            children: [
              SwitchListTile(
                title: const Text('Включить уведомления'),
                subtitle: const Text('Получать RSI алерты'),
                value: _notificationsEnabled,
                onChanged: (value) {
                  setState(() {
                    _notificationsEnabled = value;
                  });
                  _saveSettings();
                },
              ),
              SwitchListTile(
                title: const Text('Звук'),
                subtitle: const Text('Звуковые уведомления'),
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
                title: const Text('Вибрация'),
                subtitle: const Text('Вибрация при уведомлениях'),
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

          // Внешний вид
          _buildSectionCard(
            title: 'Внешний вид',
            icon: Icons.palette,
            children: [
              ListTile(
                title: const Text('Тема'),
                subtitle: Text(_theme == 'dark' ? 'Темная' : 'Светлая'),
                trailing: const Icon(Icons.arrow_forward_ios),
                onTap: () => _showThemeDialog(),
              ),
              ListTile(
                title: const Text('Язык'),
                subtitle: Text(_language == 'ru' ? 'Русский' : 'English'),
                trailing: const Icon(Icons.arrow_forward_ios),
                onTap: () => _showLanguageDialog(),
              ),
            ],
          ),

          // Данные
          _buildSectionCard(
            title: 'Данные',
            icon: Icons.data_usage,
            children: [
              SwitchListTile(
                title: const Text('Автообновление'),
                subtitle: const Text('Автоматическое обновление данных'),
                value: _autoRefresh,
                onChanged: (value) {
                  setState(() {
                    _autoRefresh = value;
                  });
                  _saveSettings();
                },
              ),
              ListTile(
                title: const Text('Интервал обновления'),
                subtitle: Text('$_refreshInterval секунд'),
                trailing: const Icon(Icons.arrow_forward_ios),
                onTap: () => _showRefreshIntervalDialog(),
              ),
              ListTile(
                title: const Text('Очистить кэш'),
                subtitle: const Text('Удалить сохраненные данные'),
                trailing: const Icon(Icons.delete),
                onTap: () => _showClearCacheDialog(),
              ),
            ],
          ),

          // Учетная запись
          _buildSectionCard(
            title: 'Учетная запись',
            icon: Icons.person,
            children: [
              ListTile(
                title: const Text('Профиль'),
                subtitle: const Text('Настройки профиля'),
                trailing: const Icon(Icons.arrow_forward_ios),
                onTap: () => _showProfileDialog(),
              ),
              ListTile(
                title: const Text('Синхронизация'),
                subtitle: const Text('Синхронизация между устройствами'),
                trailing: const Icon(Icons.sync),
                onTap: () => _showSyncDialog(),
              ),
            ],
          ),

          // О приложении
          _buildSectionCard(
            title: 'О приложении',
            icon: Icons.info,
            children: [
              ListTile(
                title: const Text('Версия'),
                subtitle: const Text('1.0.0'),
                trailing: const Icon(Icons.arrow_forward_ios),
                onTap: () => _showVersionDialog(),
              ),
              ListTile(
                title: const Text('Лицензия'),
                subtitle: const Text('Условия использования'),
                trailing: const Icon(Icons.arrow_forward_ios),
                onTap: () => _showLicenseDialog(),
              ),
              ListTile(
                title: const Text('Поддержка'),
                subtitle: const Text('Связаться с поддержкой'),
                trailing: const Icon(Icons.arrow_forward_ios),
                onTap: () => _showSupportDialog(),
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

  void _showThemeDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Выберите тему'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('Темная'),
              leading: Radio<String>(
                value: 'dark',
                groupValue: _theme,
                onChanged: (value) {
                  setState(() {
                    _theme = value!;
                  });
                  _saveSettings();
                  Navigator.pop(context);
                },
              ),
            ),
            ListTile(
              title: const Text('Светлая'),
              leading: Radio<String>(
                value: 'light',
                groupValue: _theme,
                onChanged: (value) {
                  setState(() {
                    _theme = value!;
                  });
                  _saveSettings();
                  Navigator.pop(context);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showLanguageDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Выберите язык'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('Русский'),
              leading: Radio<String>(
                value: 'ru',
                groupValue: _language,
                onChanged: (value) {
                  setState(() {
                    _language = value!;
                  });
                  _saveSettings();
                  Navigator.pop(context);
                },
              ),
            ),
            ListTile(
              title: const Text('English'),
              leading: Radio<String>(
                value: 'en',
                groupValue: _language,
                onChanged: (value) {
                  setState(() {
                    _language = value!;
                  });
                  _saveSettings();
                  Navigator.pop(context);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showRefreshIntervalDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Интервал обновления'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Текущий интервал: $_refreshInterval секунд'),
            const SizedBox(height: 16),
            Slider(
              value: _refreshInterval.toDouble(),
              min: 30,
              max: 300,
              divisions: 9,
              label: '$_refreshInterval сек',
              onChanged: (value) {
                setState(() {
                  _refreshInterval = value.round();
                });
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          ElevatedButton(
            onPressed: () {
              _saveSettings();
              Navigator.pop(context);
            },
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
  }

  void _showClearCacheDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Очистить кэш'),
        content: const Text(
            'Вы уверены, что хотите удалить все сохраненные данные?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          ElevatedButton(
            onPressed: () async {
              // Очистка кэша данных
              DataCache.clear();
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Кэш очищен')),
              );
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Очистить'),
          ),
        ],
      ),
    );
  }

  void _showProfileDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Профиль'),
        content:
            const Text('Функция профиля будет реализована в следующих версиях'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _showSyncDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Синхронизация'),
        content: const Text(
            'Функция синхронизации будет реализована в следующих версиях'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _showVersionDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('О приложении'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('RSI Widget App'),
            Text('Версия: 1.0.0'),
            SizedBox(height: 8),
            Text('Мобильное приложение для RSI алертов и виджетов'),
            SizedBox(height: 8),
            Text('© 2024 RSI Widget Team'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _showLicenseDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Лицензия'),
        content: const SingleChildScrollView(
          child: Text(
            'Условия использования будут добавлены в следующих версиях приложения.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _showSupportDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Поддержка'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Email: support@rsiwidget.app'),
            SizedBox(height: 8),
            Text('Telegram: @rsiwidget_support'),
            SizedBox(height: 8),
            Text('GitHub: github.com/rsiwidget'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
}
