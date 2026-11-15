import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../ds.dart';

/// Makes a card feel physical: it sinks slightly while pressed and springs
/// back on release. Without animations it stays still.
class DsPressable extends StatefulWidget {
  const DsPressable({
    super.key,
    required this.child,
    required this.onTap,
    this.onLongPress,
  });

  static const double pressedScale = 0.97;

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  State<DsPressable> createState() => _DsPressableState();
}

class _DsPressableState extends State<DsPressable>
    with SingleTickerProviderStateMixin {
  late final _scale = AnimationController.unbounded(vsync: this, value: 1);

  void _springTo(double target) {
    if (!mounted || MediaQuery.disableAnimationsOf(context)) return;
    final sim = SpringSimulation(
      context.ds.motion.press,
      _scale.value,
      target,
      _scale.velocity,
    );
    _scale.animateWith(sim);
  }

  @override
  void dispose() {
    _scale.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null || widget.onLongPress != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: enabled ? (_) => _springTo(DsPressable.pressedScale) : null,
      onTapUp: enabled ? (_) => _springTo(1) : null,
      onTapCancel: enabled ? () => _springTo(1) : null,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: AnimatedBuilder(
        animation: _scale,
        builder: (_, child) =>
            Transform.scale(scale: _scale.value, child: child),
        child: widget.child,
      ),
    );
  }
}
