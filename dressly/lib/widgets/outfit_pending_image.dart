import 'package:flutter/material.dart';

import '../design/ds.dart';
import '../l10n/app_text.dart';
import '../models/outfit.dart';
import 'app_image.dart';

/// What an outfit shows while its AI picture is being made: its garments,
/// dimmed, under a spinner. A render has no image for about a minute, and an
/// empty URL used to come out as a broken-image glyph that read as an error.
class OutfitPendingImage extends StatelessWidget {
  const OutfitPendingImage({
    super.key,
    required this.outfit,
    this.compact = false,
  });

  final Outfit outfit;

  /// Small tiles (a grid of three, an agenda thumbnail): no caption.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final c = ds.colors;
    final pics = [
      for (final cl in outfit.cloths)
        if (cl.thumbUrl.isNotEmpty) cl.thumbUrl,
    ].take(4).toList();
    return Container(
      color: c.surfaceHigh,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (pics.isNotEmpty)
            Opacity(
              opacity: 0.45,
              child: Padding(
                padding: EdgeInsets.all(compact ? 4 : ds.space.s),
                child: GridView.count(
                  crossAxisCount: pics.length == 1 ? 1 : 2,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 4,
                  crossAxisSpacing: 4,
                  children: [
                    for (final u in pics) AppImage.path(u, fit: BoxFit.contain),
                  ],
                ),
              ),
            )
          else
            Center(child: Icon(Icons.checkroom, size: 40, color: c.textMuted)),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: compact ? 18 : 28,
                  height: compact ? 18 : 28,
                  child: CircularProgressIndicator(
                    strokeWidth: compact ? 2 : 3,
                    color: c.accent,
                  ),
                ),
                if (!compact) ...[
                  SizedBox(height: ds.space.s),
                  Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: ds.space.s,
                      vertical: ds.space.xs / 2,
                    ),
                    decoration: BoxDecoration(
                      color: c.bg.withValues(alpha: 0.8),
                      borderRadius: ds.shape.smallRadius,
                    ),
                    child: Text(
                      tr(context, 'outfit.rendering'),
                      style: ds.typo.label,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
