import 'package:flutter/material.dart';

import '../design/ds.dart';
import '../l10n/app_text.dart';
import '../models/outfit.dart';
import 'app_image.dart';

/// One past outfit in a grid: its image (or a failure mark), delete and
/// favourite buttons, and who/what it shows. Long-press also deletes.
class OutfitHistoryCard extends StatelessWidget {
  const OutfitHistoryCard({
    super.key,
    required this.outfit,
    required this.onTap,
    this.onDelete,
    required this.onToggleFavorite,
  });

  final Outfit outfit;
  final VoidCallback onTap;

  /// Null hides the delete button (the Saved tab only unfavourites).
  final VoidCallback? onDelete;
  final VoidCallback onToggleFavorite;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final c = ds.colors;
    final failed = outfit.status == 'failed';
    final caption = failed
        ? '${tr(context, 'history.failed')} (${outfit.tierLabel})'
        : [
            if (outfit.view == 'back') tr(context, 'history.back'),
            ?outfit.modelName,
            if (outfit.cloths.isNotEmpty)
              outfit.cloths.map((c) => c.name).join(', '),
          ].join(' · ');

    return DsPressable(
      onTap: onTap,
      onLongPress: onDelete,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(ds.shape.card),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (failed)
              Center(
                child: Icon(Icons.error_outline, size: 36, color: c.danger),
              )
            else
              AppImage(
                url: outfitThumbUrl(outfit),
                cacheKey: outfitThumbUrl(outfit),
                fit: BoxFit.cover,
                memWidth: 600,
              ),
            if (onDelete != null)
              Positioned(
                top: ds.space.s,
                left: ds.space.s,
                child: _RoundIcon(
                  icon: Icons.delete_outline,
                  label: tr(context, 'common.delete'),
                  onTap: onDelete!,
                ),
              ),
            if (!failed)
              Positioned(
                top: ds.space.s,
                right: ds.space.s,
                child: _RoundIcon(
                  icon: outfit.isFavorite
                      ? Icons.favorite
                      : Icons.favorite_border,
                  color: outfit.isFavorite ? c.accent : null,
                  label: tr(
                    context,
                    outfit.isFavorite
                        ? 'history.removeFromSaved'
                        : 'history.saveToFavorites',
                  ),
                  onTap: onToggleFavorite,
                ),
              ),
            if (outfit.isManual)
              Positioned(
                top: ds.space.m,
                left: 0,
                right: 0,
                child: Center(
                  child: DsBadge(
                    text: trOr(context, 'builder.manual', 'Manual'),
                  ),
                ),
              ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: EdgeInsets.fromLTRB(
                  ds.space.s,
                  ds.space.l,
                  ds.space.s,
                  ds.space.s,
                ),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      c.bg.withValues(alpha: 0.9),
                      c.bg.withValues(alpha: 0),
                    ],
                  ),
                ),
                child: Text(
                  caption,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: ds.typo.label.copyWith(color: c.text),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoundIcon extends StatelessWidget {
  const _RoundIcon({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = context.ds.colors;
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: c.bg.withValues(alpha: 0.7),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 20, color: color ?? c.text),
        ),
      ),
    );
  }
}
