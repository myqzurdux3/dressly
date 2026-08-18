import 'package:flutter/material.dart';

import '../l10n/app_text.dart';
import '../models/outfit.dart';
import 'app_image.dart';

/// One card in an outfit grid (history, favourites).
///
/// Pulled out of the 2200-line outfit screen: as an inline closure this ~150
/// line subtree was rebuilt for every card on every `setState` of the parent,
/// including ones that only touched the prompt field.
class OutfitHistoryCard extends StatelessWidget {
  const OutfitHistoryCard({
    super.key,
    required this.outfit,
    required this.onTap,
    required this.onDelete,
    required this.onToggleFavorite,
  });

  final Outfit outfit;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback onToggleFavorite;

  @override
  Widget build(BuildContext context) {
    final failed = outfit.status == 'failed';
    return GestureDetector(
      onTap: onTap,
      onLongPress: onDelete,
      child: Card(
        clipBehavior: Clip.antiAlias,
        margin: EdgeInsets.zero,
        child: Stack(children: [
          if (failed)
            Container(
              width: double.infinity,
              height: double.infinity,
              color: Colors.red.shade900,
              child: const Center(
                child: Icon(Icons.error_outline, size: 36, color: Colors.white),
              ),
            )
          else
            Positioned.fill(
              child: AppImage(
                // Grid-sized copy, not the full render.
                url: outfitThumbUrl(outfit),
                cacheKey: outfitThumbUrl(outfit),
                fit: BoxFit.cover,
                memWidth: 600,
              ),
            ),
          // Delete (bin) — favoriting is handled by the heart, so the overflow
          // menu is gone: just the two clear actions.
          Positioned(
            top: 4,
            left: 4,
            child: DecoratedBox(
              decoration: const BoxDecoration(
                  color: Colors.black54, shape: BoxShape.circle),
              child: IconButton(
                iconSize: 20,
                padding: const EdgeInsets.all(6),
                constraints: const BoxConstraints(),
                visualDensity: VisualDensity.compact,
                tooltip: tr(context, 'common.delete'),
                icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                onPressed: onDelete,
              ),
            ),
          ),
          if (!failed)
            Positioned(
              top: 4,
              right: 4,
              // Dark disc behind the heart so it stays visible over bright
              // generated images.
              child: DecoratedBox(
                decoration: const BoxDecoration(
                    color: Colors.black54, shape: BoxShape.circle),
                child: IconButton(
                  iconSize: 24,
                  padding: const EdgeInsets.all(6),
                  constraints: const BoxConstraints(),
                  visualDensity: VisualDensity.compact,
                  tooltip: tr(context, outfit.isFavorite
                      ? 'history.removeFromSaved'
                      : 'history.saveToFavorites'),
                  icon: Icon(
                    outfit.isFavorite ? Icons.favorite : Icons.favorite_border,
                    color: outfit.isFavorite ? Colors.redAccent : Colors.white,
                  ),
                  onPressed: onToggleFavorite,
                ),
              ),
            ),
          if (outfit.isManual)
            Positioned(
              top: 6,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.brush, size: 12, color: Colors.white),
                      const SizedBox(width: 4),
                      Text(trOr(context, 'builder.manual', 'Manual'),
                          style: const TextStyle(
                              fontSize: 10, color: Colors.white)),
                    ],
                  ),
                ),
              ),
            ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Colors.black87, Colors.transparent]),
              ),
              child: Text(
                failed
                    ? '${tr(context, 'history.failed')} (${outfit.tierLabel})'
                    : [
                        if (outfit.view == 'back') tr(context, 'history.back'),
                        if (outfit.modelName != null) outfit.modelName!,
                        if (outfit.cloths.isNotEmpty)
                          outfit.cloths.map((c) => c.name).join(', '),
                      ].join(' · '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
