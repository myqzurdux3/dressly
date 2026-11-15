import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/cloth.dart';
import '../../services/clothes_service.dart';
import '../../state/paged_list.dart';
import '../../state/providers.dart';

/// Quick-filter key for "everything".
const wardrobeAll = '';

/// Quick-filter key for favourites. Not a category name (those are bare words).
const wardrobeFavorites = '*favorites';

/// The wardrobe's query: search text, quick filter and the filter sheet.
class WardrobeFilter extends Notifier<ClothFilter> {
  @override
  ClothFilter build() => ClothFilter(sort: 'newest');

  void setSearch(String text) => state = state.copyWith(
    search: text.isEmpty ? null : text,
    clearSearch: text.isEmpty,
  );

  /// [wardrobeAll], [wardrobeFavorites] or a category. The quick filters are
  /// exclusive: picking a category drops favourites and the other way round.
  void setQuick(String key) {
    final f = state;
    state = ClothFilter(
      search: f.search,
      brand: f.brand,
      color: f.color,
      cut: f.cut,
      tag: f.tag,
      sort: f.sort,
      minScore: f.minScore,
      category: key == wardrobeAll || key == wardrobeFavorites ? null : key,
      favorite: key == wardrobeFavorites,
    );
  }

  /// The filter sheet's result, keeping the search typed in the field.
  void replace(ClothFilter f) => state = f.copyWith(
    search: state.search,
    clearSearch: state.search == null,
  );
}

/// Which quick filter [f] corresponds to.
String quickKeyOf(ClothFilter f) =>
    f.favorite ? wardrobeFavorites : (f.category ?? wardrobeAll);

final wardrobeFilterProvider = NotifierProvider<WardrobeFilter, ClothFilter>(
  WardrobeFilter.new,
);

/// The wardrobe's pages. Reloads from the first page whenever the filter
/// changes; the filter is read at fetch time, so a refresh is all a new query
/// needs.
final wardrobeListProvider = Provider.autoDispose<PagedList<Cloth>>((ref) {
  final service = ref.watch(clothesServiceProvider);
  final list = PagedList<Cloth>(
    fetchPage: ({required limit, required offset}) => service.list(
      filter: ref.read(wardrobeFilterProvider),
      limit: limit,
      offset: offset,
    ),
  );
  ref.listen(wardrobeFilterProvider, (_, _) => list.refresh());
  ref.onDispose(list.dispose);
  list.refresh();
  return list;
}, dependencies: [clothesServiceProvider]);
