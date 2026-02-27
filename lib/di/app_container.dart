import 'package:get_it/get_it.dart';
import 'package:isar_db/isar_db.dart';

import '../repositories/alert_repository.dart';
import '../repositories/i_alert_repository.dart';
import '../repositories/i_watchlist_repository.dart';
import '../repositories/watchlist_repository.dart';

final GetIt sl = GetIt.instance;

/// Registers core dependencies (Isar, repositories).
/// Call once from main() after Isar.openAsync().
void registerAppDependencies(Isar isar) {
  sl
    ..registerSingleton<Isar>(isar)
    ..registerSingleton<IAlertRepository>(AlertRepository(isar))
    ..registerSingleton<IWatchlistRepository>(WatchlistRepository(isar));
}
