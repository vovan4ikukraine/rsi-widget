import 'package:isar/isar.dart';
import '../models.dart';
import 'i_watchlist_repository.dart';

/// Repository for WatchlistItem operations.
/// Encapsulates database operations and provides a clean API.
class WatchlistRepository implements IWatchlistRepository {
  final Isar isar;

  WatchlistRepository(this.isar);

  /// Get all watchlist items.
  Future<List<WatchlistItem>> getAll() async {
    return isar.watchlistItems.where().findAll();
  }

  /// Get watchlist item by symbol.
  Future<WatchlistItem?> getBySymbol(String symbol) async {
    return isar.watchlistItems
        .filter()
        .symbolEqualTo(symbol)
        .findFirst();
  }

  /// Get all watchlist items with given symbol (for duplicate check).
  Future<List<WatchlistItem>> findAllBySymbol(String symbol) async {
    return isar.watchlistItems
        .filter()
        .symbolEqualTo(symbol)
        .findAll();
  }

  /// Save or update a watchlist item.
  Future<void> put(WatchlistItem item) async {
    await isar.writeTxn(() => isar.watchlistItems.put(item));
  }

  /// Delete a watchlist item by ID.
  Future<void> delete(int id) async {
    await isar.writeTxn(() => isar.watchlistItems.delete(id));
  }

  /// Replace all watchlist items with [items] in a single transaction.
  /// Clears existing items, then puts [items].
  Future<void> replaceAll(List<WatchlistItem> items) async {
    await isar.writeTxn(() async {
      final existing = await isar.watchlistItems.where().findAll();
      for (final e in existing) {
        await isar.watchlistItems.delete(e.id);
      }
      for (final item in items) {
        await isar.watchlistItems.put(item);
      }
      return Future<void>.value();
    });
  }
}
