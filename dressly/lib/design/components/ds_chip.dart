import 'package:flutter/material.dart';

import '../ds.dart';

/// Filter pill. Selected chips invert to the text colour so the active filter
/// reads at a glance without spending the accent.
class DsChip extends StatelessWidget {
  const DsChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.leading,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// Small widget before the label (a colour dot).
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final c = ds.colors;
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? c.text : c.surface,
        // The hairline keeps an unselected chip visible on a surface-coloured
        // sheet, where its fill alone matches the background.
        shape: StadiumBorder(
          side: selected ? BorderSide.none : BorderSide(color: c.hairline),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: ds.space.l),
              child: Center(
                widthFactor: 1,
                heightFactor: 1,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (leading != null) ...[
                      leading!,
                      SizedBox(width: ds.space.xs),
                    ],
                    Text(
                      label,
                      maxLines: 1,
                      style: ds.typo.label.copyWith(
                        color: selected ? c.bg : c.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Single-choice row of [DsChip]s that scrolls sideways when it runs out of
/// room.
class DsSegment<T> extends StatelessWidget {
  const DsSegment({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
  });

  final List<(T, String)> options;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final gap = context.ds.space.s;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final (i, (v, label)) in options.indexed) ...[
            if (i > 0) SizedBox(width: gap),
            DsChip(
              label: label,
              selected: v == value,
              onTap: () => onChanged(v),
            ),
          ],
        ],
      ),
    );
  }
}
