/// App configuration: API base URL and environment.
///
/// Values are set at build time via --dart-define:
/// - dev flavor: API_BASE_URL=https://rsi-workers-dev.XXX.workers.dev
/// - prod flavor: API_BASE_URL=https://rsi-workers.vovan4ikukraine.workers.dev
///
/// Default is prod URL (safe fallback if built without flavor).
class AppConfig {
  AppConfig._();

  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://rsi-workers.vovan4ikukraine.workers.dev',
  );

  static bool get isDev =>
      apiBaseUrl.contains('-dev') || apiBaseUrl.contains('.dev.');
}
