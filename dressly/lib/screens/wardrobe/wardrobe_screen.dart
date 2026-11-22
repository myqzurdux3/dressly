import 'dart:async';

import 'package:flutter/material.dart';

import '../../state/data_bus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ds.dart';
import '../../l10n/app_text.dart';
import '../../models/cloth.dart';
import '../../services/api_client.dart';
import '../../services/clothes_service.dart';
import '../../state/paged_list.dart';
import '../../state/providers.dart';
import '../../widgets/filter_sheet.dart';
import '../cloth/add_cloth_screen.dart';
import '../cloth/cloth_detail_screen.dart';
import '../settings/settings_screen.dart';
import 'wardrobe_card.dart';
import 'wardrobe_state.dart';

/// The wardrobe tab: giant header with the count, search, quick filters,
/// and the garments as swatch cards.
class WardrobeScreen extends ConsumerStatefulWidget {
  const WardrobeScreen({super.key, this.imageBuilder});

  /// Overrides how card images are drawn (tests). Null = network images.
  final ImageBuilder? imageBuilder;

  @override
  ConsumerState<WardrobeScreen> createState() => _WardrobeScreenState();
}

class _WardrobeScreenState extends ConsumerState<WardrobeScreen> {
  final _searchCtrl = TextEditingController();
  final _scroll = ScrollController();
  Timer? _searchDebounce;
  List<String> _brands = [];
  List<String> _tags = [];

  ClothesService get _service => ref.read(clothesServiceProvider);
  PagedList<Cloth> get _list => ref.read(wardrobeListProvider);

  @override
  void initState() {
    super.initState();
    _searchCtrl.text = ref.read(wardrobeFilterProvider).search ?? '';
    _scroll.addListener(_maybeLoadMore);
    DataBus.wardrobe.addListener(_reloadList);
    // Autocomplete lists rarely change: fetched once per screen, not on every
    // refresh. Failures only cost the suggestions.
    _service
        .autocompleteBrands()
        .then((b) {
          if (mounted) setState(() => _brands = b);
        })
        .catchError((_) {});
    _service
        .autocompleteTags()
        .then((t) {
          if (mounted) setState(() => _tags = t);
        })
        .catchError((_) {});
  }

  void _reloadList() => _list.refresh();

  @override
  void dispose() {
    DataBus.wardrobe.removeListener(_reloadList);
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _maybeLoadMore() async {
    if (!_scroll.hasClients) return;
    final p = _scroll.position;
    if (p.pixels < p.maxScrollExtent - 600) return;
    final list = _list;
    if (list.isLoading || !list.hasMore) return;
    await list.loadMore();
    // A failed first page shows DsError; a failed later page keeps the cards
    // already shown, so it has to be said.
    if (mounted && list.error != null && list.items.isNotEmpty) {
      _snack('${tr(context, 'wardrobe.loadFailed')}: ${list.error}');
    }
  }

  // Search as you type, debounced so the API is not hit on every keystroke.
  void _onSearchChanged(String v) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(
      const Duration(milliseconds: 300),
      () => ref.read(wardrobeFilterProvider.notifier).setSearch(v),
    );
  }

  void _onSearchSubmitted(String v) {
    _searchDebounce?.cancel();
    ref.read(wardrobeFilterProvider.notifier).setSearch(v);
  }

  Future<void> _openFilters() async {
    final result = await showModalBottomSheet<ClothFilter>(
      context: context,
      isScrollControlled: true,
      builder: (_) => FilterSheet(
        filter: ref.read(wardrobeFilterProvider),
        availableBrands: _brands,
        availableTags: _tags,
      ),
    );
    if (result != null && mounted) {
      ref.read(wardrobeFilterProvider.notifier).replace(result);
    }
  }

  Future<void> _toggleFavorite(Cloth cloth) async {
    final list = _list;
    try {
      final nowFavorite = await _service.toggleFavorite(
        cloth.id,
        isFavorite: !cloth.isFavorite,
      );
      if (!mounted) return;
      if (ref.read(wardrobeFilterProvider).favorite && !nowFavorite) {
        // Un-favourited under the favourites filter: it no longer belongs.
        list.removeItem((c) => c.id == cloth.id);
      } else {
        // Patch the one card instead of refetching every page scrolled.
        list.replaceItem(
          (c) => c.id == cloth.id,
          cloth.copyWith(isFavorite: nowFavorite),
        );
      }
    } catch (e) {
      // The card keeps its state — the server refused — but the user has to
      // be told, or they believe it was saved.
      if (mounted) _snack('${tr(context, 'result.favoriteFailed')}: $e');
    }
  }

  Future<void> _confirmDelete(int id) async {
    final list = _list;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr(context, 'wardrobe.deleteTitle')),
        content: Text(tr(context, 'wardrobe.deleteConfirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(tr(context, 'common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(tr(context, 'common.delete')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _service.delete(id);
      list.removeItem((c) => c.id == id);
    } catch (e) {
      if (mounted) _snack('${tr(context, 'wardrobe.deleteFailed')}: $e');
    }
  }

  Future<void> _openDetail(Cloth cloth) async {
    final list = _list;
    final service = _service;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ClothDetailScreen(clothId: cloth.id)),
    );
    // The detail screen can change the cut-out or delete the garment, so
    // re-read just that one item.
    if (!mounted) return;
    try {
      list.replaceItem((c) => c.id == cloth.id, await service.get(cloth.id));
    } catch (e) {
      // Only a 404 means it is really gone. A timeout or being offline used
      // to drop the card too, silently emptying the wardrobe.
      if (e is ApiException && e.statusCode == 404) {
        list.removeItem((c) => c.id == cloth.id);
      } else if (mounted) {
        _snack('${tr(context, 'wardrobe.loadFailed')}: $e');
      }
    }
  }

  Future<void> _openAdd() async {
    final list = _list;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AddClothScreen()),
    );
    await list.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final list = ref.watch(wardrobeListProvider);
    final filter = ref.watch(wardrobeFilterProvider);
    return Scaffold(
      backgroundColor: ds.colors.bg,
      floatingActionButton: DsButton(
        label: tr(context, 'wardrobe.addClothes'),
        icon: Icons.add,
        onPressed: _openAdd,
      ),
      body: SafeArea(
        bottom: false,
        child: ListenableBuilder(
          listenable: list,
          builder: (context, _) => RefreshIndicator(
            color: ds.colors.accent,
            onRefresh: list.refresh,
            child: CustomScrollView(
              controller: _scroll,
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(
                  child: ListenableBuilder(
                    listenable: ref.watch(wardrobeTotalProvider),
                    builder: (context, _) => _header(context, list, filter),
                  ),
                ),
                ..._body(context, list, filter),
                // Room for the floating "add" button over the last row: the
                // button, its margin from the edge, then a gap.
                SliverToBoxAdapter(
                  child: SizedBox(
                    height:
                        DsButton.height +
                        kFloatingActionButtonMargin +
                        ds.space.m,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context, PagedList<Cloth> list, ClothFilter f) {
    final ds = context.ds;
    final total = ref.read(wardrobeTotalProvider).value;
    final loaded = list.items.length;
    // The server's total when it has answered; until then "60+" rather than a
    // number that is wrong.
    final count = list.hasMore ? (total ?? loaded) : loaded;
    final countLine =
        '$count${list.hasMore && total == null ? '+' : ''} '
        '${trPlural(context, 'wardrobe.item', count)}';
    final sheetActive =
        (f.brand?.isNotEmpty ?? false) ||
        (f.color?.isNotEmpty ?? false) ||
        (f.cut?.isNotEmpty ?? false) ||
        (f.tag?.isNotEmpty ?? false) ||
        (f.minScore ?? 0) > 0 ||
        (f.sort != null && f.sort != 'newest');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DsHeader(
          line1: tr(context, 'wardrobe.title1'),
          line2: tr(context, 'wardrobe.title2'),
          meta: [
            if (!list.isLoading || count > 0) countLine,
            if (!f.isEmpty) tr(context, 'wardrobe.matchFilters'),
          ],
          trailing: DsButton.icon(
            icon: Icons.settings_outlined,
            semanticLabel: tr(context, 'profile.settings'),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: ds.space.gutter),
          child: Row(
            children: [
              Expanded(
                child: DsSearchField(
                  controller: _searchCtrl,
                  hint: tr(context, 'wardrobe.searchHint'),
                  clearLabel: tr(context, 'common.clear'),
                  onChanged: _onSearchChanged,
                  onSubmitted: _onSearchSubmitted,
                ),
              ),
              SizedBox(width: ds.space.s),
              DsChip(
                label: tr(context, 'wardrobe.filters'),
                selected: sheetActive,
                onTap: _openFilters,
              ),
            ],
          ),
        ),
        SizedBox(height: ds.space.s),
        Padding(
          padding: EdgeInsets.only(left: ds.space.gutter),
          child: DsSegment<String>(
            options: [
              (wardrobeAll, tr(context, 'wardrobe.all')),
              (wardrobeFavorites, tr(context, 'wardrobe.favorites')),
              for (final c in kCategoryOptions) (c, categoryLabel(c)),
            ],
            value: quickKeyOf(f),
            onChanged: ref.read(wardrobeFilterProvider.notifier).setQuick,
          ),
        ),
        SizedBox(height: ds.space.m),
      ],
    );
  }

  List<Widget> _body(
    BuildContext context,
    PagedList<Cloth> list,
    ClothFilter f,
  ) {
    final ds = context.ds;
    final items = list.items;
    final pad = EdgeInsets.symmetric(horizontal: ds.space.gutter);
    if (items.isEmpty && list.isLoading) {
      return [
        SliverPadding(
          padding: pad,
          sliver: const SliverToBoxAdapter(child: DsSkeleton.swatchGrid()),
        ),
      ];
    }
    if (items.isEmpty && list.error != null) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: DsError(
            message: '${tr(context, 'wardrobe.loadFailed')}: ${list.error}',
            retryLabel: tr(context, 'common.retry'),
            onRetry: list.refresh,
          ),
        ),
      ];
    }
    if (items.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: DsEmpty(
            title: tr(
              context,
              f.isEmpty ? 'wardrobe.empty' : 'wardrobe.noMatch',
            ),
            message: tr(context, 'wardrobe.emptyHint'),
          ),
        ),
      ];
    }
    return [
      SliverPadding(
        padding: pad,
        sliver: SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: ds.space.s,
            mainAxisSpacing: ds.space.s,
            childAspectRatio: WardrobeCard.aspectRatio,
          ),
          delegate: SliverChildBuilderDelegate((context, i) {
            final cloth = items[i];
            return WardrobeCard(
              // Without a key the sliver matches cards by index, so
              // re-sorting left a card showing the previous garment's back.
              key: ValueKey(cloth.id),
              cloth: cloth,
              onTap: () => _openDetail(cloth),
              onLongPress: () => _confirmDelete(cloth.id),
              onToggleFavorite: () => _toggleFavorite(cloth),
              imageBuilder: widget.imageBuilder ?? WardrobeCard.networkImage,
            );
          }, childCount: items.length),
        ),
      ),
      if (list.hasMore)
        SliverPadding(
          padding: EdgeInsets.all(ds.space.l),
          sliver: SliverToBoxAdapter(
            child: Center(
              child: SizedBox.square(
                dimension: ds.space.l,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: ds.colors.textMuted,
                ),
              ),
            ),
          ),
        ),
    ];
  }
}
