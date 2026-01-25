import '../models.dart';

/// Abstract interface for watchlist persistence.
/// Implementations encapsulate Isar operations.
abstract interface class IWatchlistRepository {
  Future<List<WatchlistItem>> getAll();
  Future<WatchlistItem?> getBySymbol(String symbol);
  Future<List<WatchlistItem>> findAllBySymbol(String symbol);
  Future<void> put(WatchlistItem item);
  Future<void> delete(int id);
  Future<void> replaceAll(List<WatchlistItem> items);
}
