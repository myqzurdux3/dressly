import 'package:flutter/material.dart';

import '../ds.dart';

@immutable
class DsDay {
  const DsDay({
    required this.date,
    required this.weekday,
    this.hasPlan = false,
  });

  final DateTime date;

  /// Already localised short name ("sam").
  final String weekday;
  final bool hasPlan;
}

/// Row of equal day cells; the selected day is filled with the accent and a
/// dot marks days that already have an outfit planned.
class DsDayStrip extends StatelessWidget {
  const DsDayStrip({
    super.key,
    required this.days,
    required this.selected,
    required this.onSelect,
  });

  final List<DsDay> days;
  final DateTime selected;
  final ValueChanged<DateTime> onSelect;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Row(
      children: [
        for (final (i, d) in days.indexed) ...[
          if (i > 0) SizedBox(width: ds.space.s - 2),
          Expanded(
            child: _Cell(
              day: d,
              selected: DateUtils.isSameDay(d.date, selected),
              onTap: () => onSelect(d.date),
            ),
          ),
        ],
      ],
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({required this.day, required this.selected, required this.onTap});

  final DsDay day;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final c = ds.colors;
    final ink = selected ? c.onAccent : c.text;
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? c.accent : c.surface,
        borderRadius: ds.shape.cardRadius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: ds.space.s),
            child: Column(
              children: [
                Text(
                  day.weekday.toUpperCase(),
                  maxLines: 1,
                  style: ds.typo.monoSmall.copyWith(
                    color: selected ? c.onAccent : c.textMuted,
                  ),
                ),
                Text(
                  '${day.date.day}',
                  style: ds.typo.headline.copyWith(color: ink),
                ),
                SizedBox(height: ds.space.xs),
                Container(
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: !day.hasPlan
                        ? c.surface.withValues(alpha: 0)
                        : selected
                        ? c.onAccent
                        : c.accent,
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
