import 'package:flutter/material.dart';

import '../design/ds.dart';
import 'app_image.dart';

/// A person to dress (or a pseudo-choice: no model, random, manage…): a tall
/// tile with the photo or an icon, the name under it. Selected = accent frame.
class ModelChip extends StatelessWidget {
  const ModelChip({
    super.key,
    required this.label,
    this.thumbUrl,
    this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String? thumbUrl;
  final IconData? icon;
  final bool selected;
  final VoidCallback onTap;

  static const width = 84.0;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final c = ds.colors;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        child: SizedBox(
          width: width,
          child: Column(
            children: [
              AnimatedContainer(
                duration: ds.motion.fast,
                width: width,
                height: 104,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: BorderRadius.circular(ds.shape.small),
                  border: Border.all(
                    color: selected ? c.accent : c.surface,
                    width: 2.5,
                  ),
                ),
                child: thumbUrl == null
                    ? Icon(
                        icon ?? Icons.person_outline,
                        color: selected ? c.accent : c.textMuted,
                        size: 32,
                      )
                    : AppImage.path(thumbUrl, fit: BoxFit.cover, memWidth: 168),
              ),
              SizedBox(height: ds.space.xs),
              // Two lines: "Modèle aléatoire" and multi-word names were cut
              // mid-word on one.
              Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: ds.typo.label.copyWith(
                  color: selected ? c.text : c.textMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
