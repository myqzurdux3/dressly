import 'package:flutter/material.dart';

import '../../design/ds.dart';
import '../../models/cloth.dart';
import '../../widgets/app_image.dart';
import '../wardrobe/wardrobe_card.dart' show swatchColorOf;

/// An outfit's garments as stickers that land askew then settle: each
/// cut-out on a swatch of its own main colour.
class OutfitCollage extends StatelessWidget {
  const OutfitCollage({super.key, required this.clothes, this.play = true});

  final List<Cloth> clothes;
  final bool play;

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return DsCollage(
      play: play,
      pieces: [
        for (final c in clothes.take(4))
          ColoredBox(
            color: garmentTone(swatchColorOf(c), b).fill,
            child: c.thumbImageUrl == null
                ? Icon(
                    Icons.checkroom,
                    color: garmentTone(swatchColorOf(c), b).shade,
                  )
                : AppImage.path(
                    c.thumbImageUrl,
                    cacheKey: c.thumbImageUrl,
                    fit: BoxFit.contain,
                    memWidth: 300,
                  ),
          ),
      ],
    );
  }
}
