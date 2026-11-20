import 'package:flutter/material.dart';

import '../ds.dart';

/// One planned day: title, mono details, and up to three garment thumbnails.
/// With no thumbnails it becomes an invitation to plan ("+").
class DsPlanCard extends StatelessWidget {
  const DsPlanCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.thumbs,
    this.tone,
    this.onTap,
    this.trailing,
  });

  static const int maxThumbs = 3;

  final String title;
  final String subtitle;
  final List<Widget> thumbs;

  /// Card colours; null uses the page surface.
  final GarmentTone? tone;
  final VoidCallback? onTap;

  /// Actions after the thumbnails (e.g. mark worn, remove).
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final c = ds.colors;
    final fill = tone?.fill ?? c.surface;
    final ink = tone?.onFill ?? c.text;
    final empty = thumbs.isEmpty;

    Widget tile(Widget child) => Container(
      width: 40,
      height: 48,
      margin: EdgeInsets.only(left: ds.space.xs),
      decoration: BoxDecoration(
        color: ink.withValues(alpha: 0.12),
        borderRadius: ds.shape.smallRadius,
      ),
      padding: EdgeInsets.all(ds.space.xs),
      child: FittedBox(child: child),
    );

    return DsPressable(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: ds.space.l - 2,
          vertical: ds.space.m,
        ),
        decoration: BoxDecoration(
          color: fill,
          borderRadius: ds.shape.cardRadius,
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ds.typo.headline.copyWith(
                      color: empty && tone == null ? c.textMuted : ink,
                    ),
                  ),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ds.typo.mono.copyWith(
                      color: ink.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            ),
            if (empty && onTap != null)
              tile(Icon(Icons.add, color: c.accentText))
            else
              for (final t in thumbs.take(maxThumbs)) tile(t),
            if (trailing != null)
              IconTheme.merge(
                data: IconThemeData(color: ink),
                child: trailing!,
              ),
          ],
        ),
      ),
    );
  }
}
