import 'package:flutter/foundation.dart';

/// Fetches one page. [offset] is the number of items already loaded.
typedef PageFetcher<T> = Future<List<T>> Function({required int limit, required int offset});

/// Scroll-driven pagination for the grid screens.
///
/// The backend has always accepted `limit`/`offset` on `/clothes` and
/// `/outfits`; the app never sent them, so every screen open pulled the entire
/// wardrobe (and every refresh re-pulled it). This owns the page cursor,
/// end-of-list detection, and in-place item mutation so a favourite toggle no
/// longer costs a full refetch.
///
/// A [ChangeNotifier] rather than a `FutureBuilder`, because the list survives
/// across loads: the previous page stays visible while the next one is in
/// flight instead of the grid flashing back to a spinner.
class PagedList<T> extends ChangeNotifier {
  PagedList({required this.fetchPage, this.pageSize = 30});

  final PageFetcher<T> fetchPage;
  final int pageSize;

  final List<T> _items = [];
  bool _loading = false;
  bool _hasMore = true;
  Object? _error;
  // Guards against a stale in-flight request overwriting a newer one when the
  // user retypes a search while the previous query is still running.
  int _generation = 0;

  List<T> get items => List.unmodifiable(_items);
  bool get isLoading => _loading;
  bool get hasMore => _hasMore;
  Object? get error => _error;
  bool get isEmpty => _items.isEmpty && !_loading;

  /// Discard everything and load page one. Call after a filter/sort change.
  Future<void> refresh() async {
    _generation++;
    _hasMore = true;
    _error = null;
    await _load(generation: _generation, replace: true);
  }

  /// Load the next page. Safe to call repeatedly from a scroll listener — it
  /// no-ops while a load is in flight or once the end has been reached.
  Future<void> loadMore() async {
    if (_loading || !_hasMore) return;
    await _load(generation: _generation, replace: false);
  }

  Future<void> _load({required int generation, required bool replace}) async {
    _loading = true;
    if (replace) _error = null;
    notifyListeners();
    try {
      final offset = replace ? 0 : _items.length;
      final page = await fetchPage(limit: pageSize, offset: offset);
      if (generation != _generation) return; // superseded by a newer refresh
      if (replace) _items.clear();
      _items.addAll(page);
      // A short page means the server has nothing left to give.
      _hasMore = page.length >= pageSize;
      _error = null;
    } catch (e) {
      if (generation != _generation) return;
      _error = e;
      if (replace) _items.clear();
    } finally {
      if (generation == _generation) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  /// Replace one item in place — used after a favourite toggle or a rating
  /// change, instead of refetching every page the user has scrolled through.
  void replaceItem(bool Function(T) test, T updated) {
    final i = _items.indexWhere(test);
    if (i == -1) return;
    _items[i] = updated;
    notifyListeners();
  }

  /// Drop one item locally (after a delete) without a round trip.
  void removeItem(bool Function(T) test) {
    final before = _items.length;
    _items.removeWhere(test);
    if (_items.length != before) notifyListeners();
  }

  /// Insert a freshly created item at the top.
  void prepend(T item) {
    _items.insert(0, item);
    notifyListeners();
  }
}
