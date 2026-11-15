import 'package:flutter/material.dart';

import '../../../design/ds.dart';
import '../../../l10n/app_text.dart';
import '../../../models/cloth.dart';

/// One colour of the garment: the colour (tap to pick from the palette), how
/// much of the garment it covers, and a remove button. The parent owns the
/// list.
class ColorEditorRow extends StatelessWidget {
  const ColorEditorRow({
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
    final ds = context.ds;
    final c = ds.colors;
    final b = Theme.of(context).brightness;
    return Padding(
      padding: EdgeInsets.only(bottom: ds.space.s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Semantics(
                  button: true,
                  label: tr(context, 'colorRow.color'),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(ds.shape.pill),
                    onTap: () async {
                      final picked = await showColorPalette(
                        context,
                        value.color,
                      );
                      if (picked != null) {
                        onChanged(
                          ClothColor(color: picked, dominance: value.dominance),
                        );
                      }
                    },
                    child: Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: ds.space.m,
                        vertical: ds.space.s,
                      ),
                      decoration: BoxDecoration(
                        color: c.surface,
                        borderRadius: BorderRadius.circular(ds.shape.pill),
                      ),
                      child: Row(
                        children: [
                          _Dot(color: garmentTone(value.color, b).fill),
                          SizedBox(width: ds.space.s),
                          Expanded(
                            child: Text(
                              colorName(context, value.color),
                              style: ds.typo.bodyStrong,
                            ),
                          ),
                          Icon(Icons.expand_more, color: c.textMuted),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Semantics(
                button: true,
                label: tr(context, 'colorRow.remove'),
                excludeSemantics: true,
                child: IconButton(
                  onPressed: onDelete,
                  icon: Icon(Icons.delete_outline, color: c.textMuted),
                ),
              ),
            ],
          ),
          SizedBox(height: ds.space.xs),
          DsSegment<String>(
            options: [
              for (final d in kDominanceTiers) (d, dominanceLabel(context, d)),
            ],
            value: value.dominance,
            onChanged: (d) =>
                onChanged(ClothColor(color: value.color, dominance: d)),
          ),
        ],
      ),
    );
  }
}

/// The palette, in a sheet. Returns the picked colour, or null.
Future<String?> showColorPalette(BuildContext context, String current) {
  final b = Theme.of(context).brightness;
  return showDsSheet<String>(
    context,
    title: tr(context, 'colorRow.color'),
    child: Builder(
      builder: (context) {
        final ds = context.ds;
        return Wrap(
          spacing: ds.space.xs,
          runSpacing: ds.space.xs,
          children: [
            for (final name in kColorPalette)
              DsChip(
                label: colorName(context, name),
                selected: name == current,
                leading: _Dot(color: garmentTone(name, b).fill),
                onTap: () => Navigator.pop(context, name),
              ),
          ],
        );
      },
    ),
  );
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 16,
    height: 16,
    decoration: BoxDecoration(
      color: color,
      shape: BoxShape.circle,
      border: Border.all(color: context.ds.colors.hairline),
    ),
  );
}
