import 'package:flutter/material.dart';

import 'app_image.dart';

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

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(children: [
        Container(
          decoration: BoxDecoration(
            border: Border.all(
                color: selected
                    ? Theme.of(context).colorScheme.primary
                    : Colors.transparent,
                width: 3),
            borderRadius: BorderRadius.circular(12),
            color: Colors.blueGrey.shade900,
          ),
          width: 80,
          height: 100,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(9),
            child: thumbUrl == null
                ? Icon(icon ?? Icons.person, color: Colors.white38, size: 36)
                : AppImage.path(thumbUrl, fit: BoxFit.contain, memWidth: 160),
          ),
        ),
        const SizedBox(height: 4),
        SizedBox(
          width: 80,
          // Two lines: "Random model" and any model named with more than one
          // word were cut to "Modèle aléat…" on a single line.
          child: Text(label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12)),
        ),
      ]),
    );
  }
}

