import 'package:flutter/material.dart';

import '../l10n/app_text.dart';
import '../models/cloth.dart';

/// Editable row: a color (dropdown) + a dominance tier (segmented selector),
/// with a delete button. Stateless; the parent owns the list.
class ColorRow extends StatelessWidget {
  const ColorRow({
    super.key,
    required this.value,
    required this.onChanged,
    required this.onDelete,
  });

  final ClothColor value;
  final ValueChanged<ClothColor> onChanged;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              initialValue: kColorPalette.contains(value.color) ? value.color : null,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText: tr(context, 'colorRow.color'),
              ),
              items: kColorPalette
                  .map((c) => DropdownMenuItem(value: c, child: Text(colorName(context, c))))
                  .toList(),
              onChanged: (v) {
                if (v != null) onChanged(ClothColor(color: v, dominance: value.dominance));
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SegmentedButton<String>(
              segments: kDominanceTiers
                  .map((d) =>
                      ButtonSegment(value: d, label: Text(dominanceLabel(context, d))))
                  .toList(),
              selected: {value.dominance},
              showSelectedIcon: false,
              onSelectionChanged: (s) {
                onChanged(ClothColor(color: value.color, dominance: s.first));
              },
            ),
          ),
          IconButton(
            onPressed: onDelete,
            icon: const Icon(Icons.delete_outline),
            tooltip: tr(context, 'colorRow.remove'),
          ),
        ],
      ),
    );
  }
}