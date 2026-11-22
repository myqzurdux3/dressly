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

  /// Icon size inside a tab.
  static const double _icon = 22;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    // The bar has a fixed width budget; past 1.3× the labels would push the
    // icons off the pill.
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.3,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Every active pill gets the width of the widest label, so the bar
          // keeps one width whatever the selection and the icons never jump.
          final scaler = MediaQuery.textScalerOf(context);
          // Measured as the Text widget will paint it: on top of the
          // inherited default style.
          final style = DefaultTextStyle.of(context).style.merge(ds.typo.label);
          var widest = 0.0;
          for (final item in items) {
            final tp = TextPainter(
              text: TextSpan(text: item.label, style: style),
              textDirection: Directionality.of(context),
              textScaler: scaler,
              maxLines: 1,
            )..layout();
            if (tp.width > widest) widest = tp.width;
            tp.dispose();
          }
          final pad = ds.space.m * 2;
          final idle = (_icon + pad).clamp(48.0, double.infinity);
          final inset = (ds.space.xs + 2) * 2;
          // On a narrow screen at a large text size the widest label may not
          // fit: the active pill then takes what is left and the label
          // ellipsizes, rather than the bar overflowing.
          final room = constraints.maxWidth - inset - idle * (items.length - 1);
          final activeWidth = (_icon + ds.space.s + widest + pad)
              .ceilToDouble()
              .clamp(idle, room < idle ? idle : room);
          return Container(
            height: height,
            padding: EdgeInsets.all(inset / 2),
            decoration: BoxDecoration(
              color: ds.colors.surface,
              borderRadius: ds.shape.pillRadius,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (i, item) in items.indexed)
                  _Tab(
                    item: item,
                    active: i == index,
                    width: i == index ? activeWidth : idle,
                    onTap: () => onTap(i),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.item,
    required this.active,
    required this.width,
    required this.onTap,
  });

  final DsTabItem item;
  final bool active;

  /// Fixed width: the widest label's for the active tab, the icon's otherwise.
  final double width;
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
          width: width,
          height: double.infinity,
          alignment: Alignment.center,
          padding: EdgeInsets.symmetric(horizontal: ds.space.m),
          decoration: BoxDecoration(
            color: active ? c.accent : c.surface.withValues(alpha: 0),
            borderRadius: ds.shape.pillRadius,
          ),
          clipBehavior: Clip.hardEdge,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(item.icon, size: DsTabBar._icon, color: ink),
              // The gap lives inside the Flexible: while the pill is still
              // growing it may have no room, and a fixed gap would overflow.
              if (active)
                Flexible(
                  child: Padding(
                    padding: EdgeInsetsDirectional.only(start: ds.space.s),
                    child: Text(
                      item.label,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: ds.typo.label.copyWith(color: ink),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
