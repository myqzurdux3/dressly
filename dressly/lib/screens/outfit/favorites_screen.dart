import 'package:flutter/material.dart';

import '../../l10n/app_text.dart';

import '../../app.dart';
import '../../models/outfit.dart';
import '../../state/paged_list.dart';
import '../../widgets/app_image.dart';
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
      fetchPage: ({required limit, required offset}) => outfitsServiceOf(context)
          .favorites(
              sort: _query.sort,
              model: _query.model,
              limit: limit,
              offset: offset),
    );
    _reload();
  }

  @override
  void dispose() {
    _outfits.dispose();
    super.dispose();
  }

  Future<void> _reload() => _outfits.refresh();

  Future<void> _openSort() async {
    // Saved tab is already favorites-only, so hide the Favorites chip — but the
    // model filter still applies.
    final result =
        await showOutfitSortSheet(context, _query, showFavoriteFilter: false);
    if (result == null || !mounted) return;
    setState(() => _query = result);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'fav.title')), actions: [
        IconButton(
          tooltip: tr(context, 'fav.sort'),
          icon: Icon(Icons.sort,
              color: _query.isActive
                  ? Theme.of(context).colorScheme.primary
                  : null),
          onPressed: _openSort,
        ),
      ]),
      body: PagedGrid<Outfit>(
        controller: _outfits,
        onRefresh: _reload,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
          childAspectRatio: 0.85,
        ),
        emptyBuilder: (context) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.favorite_border, size: 64, color: Colors.grey),
              const SizedBox(height: 12),
              Text(tr(context, 'fav.empty')),
              const SizedBox(height: 4),
              Text(tr(context, 'fav.emptyHint'),
                  style: const TextStyle(color: Colors.grey)),
            ],
          ),
        ),
        itemBuilder: (context, outfit) => _FavCard(
          outfit: outfit,
          onTap: () => _showDetail(outfit),
          onUnfavorite: () async {
            try {
              await outfitsServiceOf(context)
                  .toggleFavorite(outfit.id, isFavorite: false);
              // This screen only ever shows favourites, so the card is simply
              // gone — no need to refetch every page to learn that.
              _outfits.removeItem((o) => o.id == outfit.id);
            } catch (_) {}
          },
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

class _FavCard extends StatelessWidget {
  const _FavCard(
      {required this.outfit, required this.onTap, required this.onUnfavorite});
  final Outfit outfit;
  final VoidCallback onTap;
  final VoidCallback onUnfavorite;

  @override
  Widget build(BuildContext context) {
    final failed = outfit.status == 'failed';
    return GestureDetector(
      onTap: onTap,
      child: Card(
        clipBehavior: Clip.antiAlias,
        margin: EdgeInsets.zero,
        child: Stack(children: [
          if (failed)
            Container(color: Colors.red.shade900, child: const Center(child: Icon(Icons.error_outline, color: Colors.white)))
          else
            Positioned.fill(
              child: AppImage(
                // Grid card: take the server thumbnail rather than the
                // full-resolution render.
                url: outfitThumbUrl(outfit),
                cacheKey: outfitThumbUrl(outfit),
                fit: BoxFit.cover,
                memWidth: 600,
              ),
            ),
          Positioned(
            top: 6, left: 6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                  color: Colors.black54, borderRadius: BorderRadius.circular(6)),
              child: Text(
                  outfit.view == 'back'
                      ? tr(context, 'card.back')
                      : tr(context, 'card.front'),
                  style: const TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                      color: Colors.white)),
            ),
          ),
          Positioned(
            top: 4, right: 4,
            child: GestureDetector(
              onTap: onUnfavorite,
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: const BoxDecoration(
                    color: Colors.black54, shape: BoxShape.circle),
                child: const Icon(Icons.favorite,
                    color: Colors.redAccent, size: 22),
              ),
            ),
          ),
          Positioned(
            left: 0, right: 0, bottom: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    stops: [0.0, 0.75, 1.0],
                    colors: [Colors.black87, Colors.black54, Colors.transparent]),
              ),
              child: Text(
                [
                  if (outfit.modelName != null) outfit.modelName!,
                  if (outfit.cloths.isNotEmpty)
                    outfit.cloths.map((c) => c.name).join(', '),
                ].join(' · '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: Colors.white),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

