import 'package:flutter/material.dart';

import '../../state/data_bus.dart';

import '../../l10n/app_text.dart';

import '../../app.dart';
import '../../design/ds.dart';
import '../../models/outfit.dart';
import '../../state/paged_list.dart';
import '../../widgets/outfit_history_card.dart';
import '../../widgets/outfit_sort_sheet.dart';
import '../../widgets/paged_grid.dart';
import 'outfit_result_dialog.dart';

/// Grid of outfits the user has favorited. Tap one to open the full outfit
/// dialog — the same one used right after generating — so a saved outfit can
/// be edited (swap clothes), regenerated, marked worn, downloaded, or removed.
class FavoritesScreen extends StatefulWidget {
  const FavoritesScreen({super.key});

  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends State<FavoritesScreen> {
  late final PagedList<Outfit> _outfits;
  OutfitQuery _query = const OutfitQuery();

  @override
  void initState() {
    super.initState();
    _outfits = PagedList<Outfit>(
      fetchPage: ({required limit, required offset}) =>
          outfitsServiceOf(context).favorites(
            sort: _query.sort,
            model: _query.model,
            limit: limit,
            offset: offset,
          ),
    );
    _reload();
    DataBus.outfits.addListener(_reload);
  }

  @override
  void dispose() {
    DataBus.outfits.removeListener(_reload);
    _outfits.dispose();
    super.dispose();
  }

  Future<void> _reload() => _outfits.refresh();

  Future<void> _openSort() async {
    // Saved tab is already favorites-only, so hide the Favorites chip — but the
    // model filter still applies.
    final result = await showOutfitSortSheet(
      context,
      _query,
      showFavoriteFilter: false,
    );
    if (result == null || !mounted) return;
    setState(() => _query = result);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    Widget header({bool sortable = true}) => DsHeader(
      line1: tr(context, 'fav.title1'),
      line2: tr(context, 'fav.title2'),
      // A dot when a sort or filter is on, so it is not forgotten.
      trailing: !sortable
          ? null
          : Badge(
              isLabelVisible: _query.isActive,
              backgroundColor: ds.colors.accent,
              smallSize: 10,
              child: DsButton.icon(
                icon: Icons.sort,
                semanticLabel: tr(context, 'fav.sort'),
                onPressed: _openSort,
              ),
            ),
    );
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: PagedGrid<Outfit>(
          controller: _outfits,
          onRefresh: _reload,
          header: (_) => header(),
          padding: EdgeInsets.fromLTRB(
            ds.space.gutter,
            0,
            ds.space.gutter,
            ds.space.xl,
          ),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: ds.space.s,
            mainAxisSpacing: ds.space.s,
            childAspectRatio: 0.8,
          ),
          emptyBuilder: (context) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Nothing to sort: no sort button. It stays while a filter is
              // on, since that filter may be why the list is empty.
              header(sortable: _query.isActive),
              Expanded(
                child: DsEmpty(
                  title: tr(context, 'fav.empty'),
                  message: tr(context, 'fav.emptyHint'),
                ),
              ),
            ],
          ),
          itemBuilder: (context, outfit) => OutfitHistoryCard(
            key: ValueKey(outfit.id),
            outfit: outfit,
            onTap: () => _showDetail(outfit),
            onToggleFavorite: () async {
              try {
                await outfitsServiceOf(
                  context,
                ).toggleFavorite(outfit.id, isFavorite: false);
                // This screen only ever shows favourites, so the card is
                // simply gone — no need to refetch every page to learn that.
                _outfits.removeItem((o) => o.id == outfit.id);
              } catch (e) {
                // Silently ignored before: the heart stayed filled and the
                // user had no idea the removal had failed.
                if (!mounted) return;
                ScaffoldMessenger.of(this.context).showSnackBar(
                  SnackBar(
                    content: Text(
                      '${tr(this.context, 'result.favoriteFailed')}: $e',
                    ),
                  ),
                );
              }
            },
          ),
        ),
      ),
    );
  }

  void _showDetail(Outfit o) async {
    // Reuse the post-generation dialog: edit clothes, regenerate, back view,
    // mark worn, download, (un)favorite, delete — all in one place. Any change
    // (including unfavoriting or deleting) is reflected by reloading on close.
    await showDialog<bool>(
      context: context,
      builder: (_) => OutfitResultDialog(outfit: o, onChanged: (_) {}),
    );
    if (mounted) _reload();
  }
}
