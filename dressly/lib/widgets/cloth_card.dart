import 'package:flutter/material.dart';

import '../l10n/app_text.dart';
import '../models/cloth.dart';
import 'app_image.dart';

/// Grid tile: the selected cutout shown large (full garment, not cropped),
/// with a small thumbnail of the other side in the corner. Tapping that
/// thumbnail swaps the big image (front ⇄ back) in place; tapping the garment
/// itself opens the detail screen.
class ClothCard extends StatefulWidget {
  const ClothCard({
    super.key,
    required this.cloth,
    required this.onTap,
    this.onLongPress,
    this.onToggleFavorite,
  });

  final Cloth cloth;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onToggleFavorite;

  @override
  State<ClothCard> createState() => _ClothCardState();
}

class _ClothCardState extends State<ClothCard> {
  bool _showBack = false;

  ClothImage? _imageOfRole(String role) {
    for (final im in widget.cloth.images) {
      if (im.role == role) return im;
    }
    return null;
  }

  /// Cards are grid-sized, so they take the server's thumbnail when there is
  /// one — a card used to pull the full 1600 px cut-out to draw it at ~200 px.
  String? _url(ClothImage? im) => im?.thumbnailUrl;

  @override
  Widget build(BuildContext context) {
    final cloth = widget.cloth;
    final frontImg = _imageOfRole('front') ??
        (cloth.images.isNotEmpty ? cloth.images.first : null);
    final backImg = _imageOfRole('back');
    final canSwap = frontImg != null && backImg != null;

    // Big image = the currently-selected side; thumbnail = the other side.
    final bigImg = (_showBack && backImg != null) ? backImg : frontImg;
    final big = _url(bigImg);
    final other = (_showBack && backImg != null) ? frontImg : backImg;
    final otherUrl = _url(other);
    // "Review": any image where the user still has a choice to make — a crop
    // decision (cut-out vs original still pending) or an enhancement candidate
    // waiting for keep/discard.
    final pendingReview = cloth.images.any((im) =>
        im.bgAccepted == 'pending' || im.enhanceStatus == 'ready');

    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Image area — the selected cutout on a soft background.
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.blueGrey.shade900, Colors.blueGrey.shade800],
                      ),
                    ),
                  ),
                  if (big != null)
                    AppImage.path(
                      big,
                      cacheKey: big,
                      fit: BoxFit.contain,
                      memWidth: 600, // sharper thumbnails (was too soft)
                    )
                  else
                    const Center(
                        child: Icon(Icons.image_outlined, size: 44, color: Colors.white38)),
                  // Thumbnail of the other side — TAP IT to swap (front ⇄ back)
                  // without leaving the grid. Its own gesture wins over the
                  // card's tap, so the detail page only opens from the garment.
                  if (canSwap && otherUrl != null)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: GestureDetector(
                        onTap: () => setState(() => _showBack = !_showBack),
                        child: Tooltip(
                          message: _showBack ? tr(context, 'card.showFront') : tr(context, 'card.showBack'),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: Container(
                              width: 44,
                              height: 56,
                              decoration: BoxDecoration(
                                color: Colors.black45,
                                border: Border.all(color: Colors.white54),
                              ),
                              child: Stack(children: [
                                AppImage.path(
                                  otherUrl,
                                  cacheKey: otherUrl,
                                  fit: BoxFit.contain,
                                  memWidth: 88,
                                ),
                                Positioned(
                                  bottom: 0,
                                  left: 0,
                                  right: 0,
                                  child: Container(
                                    color: Colors.black54,
                                    padding: const EdgeInsets.symmetric(vertical: 1),
                                    child: Text(
                                      _showBack ? tr(context, 'card.front') : tr(context, 'card.back'),
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                          fontSize: 8,
                                          fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                ),
                              ]),
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (cloth.images.length > 2)
                    Positioned(
                      bottom: 6,
                      right: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text('+${cloth.images.length - 2}',
                            style: const TextStyle(fontSize: 11)),
                      ),
                    ),
                  if (pendingReview)
                    Positioned(
                      top: 8,
                      left: 8,
                      child: Tooltip(
                        message: tr(context, 'card.needsReview'),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                          decoration: BoxDecoration(
                            color: Colors.amber.shade700,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(tr(context, 'review.badgeReview'),
                              style: const TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.black)),
                        ),
                      ),
                    ),
                  if (cloth.score > 0)
                    Positioned(
                      bottom: 8,
                      left: 8,
                      child: Tooltip(
                        message: '${tr(context, 'card.rating')} ${cloth.score}/5',
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            const Icon(Icons.star, size: 12, color: Colors.amber),
                            const SizedBox(width: 2),
                            Text('${cloth.score}',
                                style: const TextStyle(
                                    fontSize: 10, fontWeight: FontWeight.bold)),
                          ]),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            // Info area.
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(children: [
                    Expanded(
                      child: Text(
                        cloth.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 14),
                      ),
                    ),
                    if (widget.onToggleFavorite != null)
                      GestureDetector(
                        onTap: widget.onToggleFavorite,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: Icon(
                            cloth.isFavorite
                                ? Icons.favorite
                                : Icons.favorite_border,
                            size: 18,
                            color: cloth.isFavorite
                                ? Colors.redAccent
                                : Colors.white54,
                          ),
                        ),
                      ),
                  ]),
                  if (cloth.brand.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Text(
                        cloth.brand,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, color: Colors.white60),
                      ),
                    ),
                  if (cloth.colors.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Row(
                        children: [
                          ...cloth.colors.take(5).map((c) => Padding(
                                padding: const EdgeInsets.only(right: 4),
                                child: Tooltip(
                                  message: '${colorName(context, c.color)} · ${dominanceLabel(context, c.dominance)}',
                                  child: _ColorDot(color: c.color),
                                ),
                              )),
                        ],
                      ),
                    ),
                  if (cloth.customTags.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Wrap(
                        spacing: 4,
                        runSpacing: 2,
                        children: cloth.customTags
                            .take(3)
                            .map((t) => Text('#$t',
                                style: const TextStyle(fontSize: 11, color: Colors.white54)))
                            .toList(),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({required this.color});
  final String color;

  Color get _swatch {
    switch (color.toLowerCase()) {
      case 'black':
        return Colors.black;
      case 'white':
        return Colors.white;
      case 'grey':
      case 'gray':
        return Colors.grey;
      case 'blue':
        return Colors.blue;
      case 'red':
        return Colors.red;
      case 'green':
        return Colors.green;
      case 'yellow':
        return Colors.yellow;
      case 'beige':
        return const Color(0xFFE8DCC4);
      case 'brown':
        return Colors.brown;
      case 'orange':
        return Colors.orange;
      case 'purple':
        return Colors.purple;
      case 'pink':
        return Colors.pink;
      default:
        return Colors.blueGrey;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        color: _swatch,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white24, width: 1),
      ),
    );
  }
}