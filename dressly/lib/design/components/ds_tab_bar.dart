import 'package:flutter/material.dart';

import '../ds.dart';

@immutable
class DsTabItem {
  const DsTabItem({required this.icon, required this.label});

  final IconData icon;
  final String label;
}

/// Floating pill navigation. The active tab grows into an accent pill with its
/// label; the others show only their icon (their label stays available to
/// screen readers).
class DsTabBar extends StatelessWidget {
  const DsTabBar({
    super.key,
    required this.items,
    required this.index,
    required this.onTap,
  });

  /// Height of the pill itself, without the floating margin.
  static const double height = 60;

  final List<DsTabItem> items;
  final int index;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    // The bar has a fixed width budget; past 1.3× the labels would push the
    // icons off the pill.
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.3,
      child: Container(
        height: height,
        padding: EdgeInsets.all(ds.space.xs + 2),
        decoration: BoxDecoration(
          color: ds.colors.surface,
          borderRadius: ds.shape.pillRadius,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (i, item) in items.indexed)
              _Tab(item: item, active: i == index, onTap: () => onTap(i)),
          ],
        ),
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({required this.item, required this.active, required this.onTap});

  final DsTabItem item;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final c = ds.colors;
    final ink = active ? c.onAccent : c.textMuted;
    return Semantics(
      selected: active,
      button: true,
      label: item.label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: ds.motion.base,
          curve: ds.motion.standard,
          constraints: const BoxConstraints(minWidth: 48),
          height: double.infinity,
          alignment: Alignment.center,
          padding: EdgeInsets.symmetric(horizontal: ds.space.m),
          decoration: BoxDecoration(
            color: active ? c.accent : c.surface.withValues(alpha: 0),
            borderRadius: ds.shape.pillRadius,
          ),
          child: AnimatedSize(
            duration: ds.motion.base,
            curve: ds.motion.standard,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(item.icon, size: 22, color: ink),
                if (active) ...[
                  SizedBox(width: ds.space.s),
                  Text(
                    item.label,
                    maxLines: 1,
                    style: ds.typo.label.copyWith(color: ink),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
