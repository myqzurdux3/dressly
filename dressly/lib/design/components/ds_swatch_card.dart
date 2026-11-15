import 'package:flutter/material.dart';

import '../ds.dart';

/// A garment shown as a fabric swatch: its photo on a fill drawn from its
/// own colour, name and wear count underneath, an optional stock badge.
class DsSwatchCard extends StatelessWidget {
  const DsSwatchCard({
    super.key,
    required this.image,
    required this.name,
    this.subtitle,
    required this.tone,
    this.badge,
    this.badgeTone = DsBadgeTone.neutral,
    this.trailing,
    required this.onTap,
    this.onLongPress,
  });

  /// Width / height. Grids use it for `childAspectRatio`.
  static const double aspectRatio = 0.82;

  final Widget image;
  final String name;
  final String? subtitle;
  final GarmentTone tone;
  final String? badge;
  final DsBadgeTone badgeTone;

  /// Top-right slot, typically the favourite toggle.
  final Widget? trailing;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final pad = ds.space.m;
    return DsPressable(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Semantics(
        button: true,
        label: [name, ?subtitle].join(', '),
        child: ClipRRect(
          borderRadius: ds.shape.cardRadius,
          child: ColoredBox(
            color: tone.fill,
            child: Stack(
              children: [
                Positioned.fill(
                  child: Padding(
                    padding: EdgeInsets.all(pad),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Centred: in a start-aligned column the box
                        // would sit against the left edge.
                        Expanded(
                          child: Center(
                            child: FractionallySizedBox(
                              heightFactor: 0.88,
                              widthFactor: 0.8,
                              child: FittedBox(child: image),
                            ),
                          ),
                        ),
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ds.typo.bodyStrong.copyWith(
                            color: tone.onFill,
                          ),
                        ),
                        if (subtitle != null)
                          Text(
                            subtitle!.toUpperCase(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: ds.typo.monoSmall.copyWith(
                              color: tone.onFill.withValues(alpha: 0.75),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (badge != null)
                  Positioned(
                    top: pad,
                    left: pad,
                    child: DsBadge(text: badge!, tone: badgeTone, on: tone),
                  ),
                if (trailing != null)
                  Positioned(
                    top: ds.space.xs,
                    right: ds.space.xs,
                    child: IconTheme.merge(
                      data: IconThemeData(color: tone.onFill),
                      child: trailing!,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
