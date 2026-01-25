import 'package:get_it/get_it.dart';
import 'package:isar/isar.dart';

import '../repositories/alert_repository.dart';
import '../repositories/i_alert_repository.dart';
import '../repositories/i_watchlist_repository.dart';
import '../repositories/watchlist_repository.dart';

final GetIt sl = GetIt.instance;

/// Registers core dependencies (Isar, repositories).
/// Call once from main() after Isar.open().
void registerAppDependencies(Isar isar) {
  sl
    ..registerSingleton<Isar>(isar)
    ..registerSingleton<IAlertRepository>(AlertRepository(isar))
    ..registerSingleton<IWatchlistRepository>(WatchlistRepository(isar));
}
