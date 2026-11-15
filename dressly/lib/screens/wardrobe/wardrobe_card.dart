import 'package:flutter/material.dart';

import '../../design/ds.dart';
import '../../l10n/app_text.dart';
import '../../models/cloth.dart';
import '../../widgets/app_image.dart';

/// Draws one image of the card. Injected so tests need no network.
typedef ImageBuilder = Widget Function(String path, int memWidth);

/// The colour a garment's card is dyed with: its dominant colour, else the
/// first one listed, else none (neutral card).
String swatchColorOf(Cloth c) {
  for (final col in c.colors) {
    if (col.dominance == 'full') return col.color;
  }
  return c.colors.isEmpty ? '' : c.colors.first.color;
}

/// A wardrobe garment as a [DsSwatchCard]: cut-out on its own colour, brand
/// and rating, a heart, and — when both sides were photographed — a small
/// thumbnail of the other side that swaps front and back in place.
class WardrobeCard extends StatefulWidget {
  const WardrobeCard({
    super.key,
    required this.cloth,
    required this.onTap,
    this.onLongPress,
    this.onToggleFavorite,
    this.imageBuilder = networkImage,
  });

  static const aspectRatio = DsSwatchCard.aspectRatio;

  /// Default [imageBuilder]: the server image through the shared cache.
  static Widget networkImage(String path, int memWidth) =>
      AppImage.path(path, cacheKey: path, memWidth: memWidth);

  final Cloth cloth;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onToggleFavorite;
  final ImageBuilder imageBuilder;

  @override
  State<WardrobeCard> createState() => _WardrobeCardState();
}

class _WardrobeCardState extends State<WardrobeCard> {
  bool _showBack = false;

  ClothImage? _ofRole(String role) {
    for (final im in widget.cloth.images) {
      if (im.role == role) return im;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final cloth = widget.cloth;
    final tone = garmentTone(
      swatchColorOf(cloth),
      Theme.of(context).brightness,
    );
    final front =
        _ofRole('front') ?? (cloth.images.isEmpty ? null : cloth.images.first);
    final back = _ofRole('back');
    final swapped = _showBack && back != null;
    final main = swapped ? back : front;
    final other = swapped ? front : back;
    final mainPath = main?.thumbnailUrl;
    final otherPath = other?.thumbnailUrl;

    // Any image still waiting for a user decision: the cut-out to accept or
    // an enhancement to keep or discard.
    final pendingReview = cloth.images.any(
      (im) => im.bgAccepted == 'pending' || im.enhanceStatus == 'ready',
    );

    final subtitle = [
      if (cloth.brand.isNotEmpty) cloth.brand,
      if (cloth.score > 0) '${cloth.score}/5',
    ].join(' · ');

    return DsSwatchCard(
      image: mainPath == null || mainPath.isEmpty
          ? Icon(Icons.checkroom, size: ds.space.xxl, color: tone.shade)
          // DsSwatchCard fits its image with a FittedBox (unbounded
          // constraints): give the network image a square box to fill and
          // let the FittedBox scale that box down.
          : SizedBox.square(
              dimension: 400,
              child: widget.imageBuilder(mainPath, 400),
            ),
      name: cloth.name,
      subtitle: subtitle.isEmpty ? null : subtitle,
      tone: tone,
      badge: pendingReview ? tr(context, 'card.review') : null,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      trailing: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            button: true,
            label: tr(context, 'wardrobe.favoriteTooltip'),
            excludeSemantics: true,
            child: SizedBox.square(
              dimension: 44,
              child: IconButton(
                padding: EdgeInsets.zero,
                onPressed: widget.onToggleFavorite,
                icon: Icon(
                  cloth.isFavorite ? Icons.favorite : Icons.favorite_border,
                  color: cloth.isFavorite ? ds.colors.accent : tone.onFill,
                ),
              ),
            ),
          ),
          if (otherPath != null && otherPath.isNotEmpty)
            Semantics(
              button: true,
              label: tr(context, swapped ? 'card.showFront' : 'card.showBack'),
              excludeSemantics: true,
              child: GestureDetector(
                onTap: () => setState(() => _showBack = !_showBack),
                // On the contrast colour of the card: the swatch is the
                // garment's own colour, so a pink back on a pink card
                // vanished.
                child: Container(
                  width: 36,
                  height: 44,
                  padding: const EdgeInsets.all(2),
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: tone.onFill,
                    borderRadius: ds.shape.smallRadius,
                  ),
                  child: widget.imageBuilder(otherPath, 80),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
