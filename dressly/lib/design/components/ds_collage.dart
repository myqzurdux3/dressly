import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../ds.dart';

/// The "outfit generated" moment: pieces land scattered and tilted like
/// stickers, then snap into a tidy two-column grid one after another.
class DsCollage extends StatefulWidget {
  const DsCollage({super.key, required this.pieces, this.play = true});

  /// Marks each piece's transform (lets tests read its rotation).
  static const pieceKey = ValueKey('ds-collage-piece');

  /// Delay between two pieces starting to settle.
  static const stagger = Duration(milliseconds: 60);

  final List<Widget> pieces;

  /// False shows the settled grid straight away.
  final bool play;

  /// How long the whole collage takes to settle for [count] pieces.
  static Duration totalDuration(int count, DsMotion motion) =>
      motion.slow * 2 + stagger * math.max(0, count - 1);

  @override
  State<DsCollage> createState() => _DsCollageState();
}

class _DsCollageState extends State<DsCollage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final motion = context.ds.motion;
    _c.duration = DsCollage.totalDuration(widget.pieces.length, motion);
    final still = !widget.play || MediaQuery.disableAnimationsOf(context);
    if (still) {
      _c.value = 1;
    } else if (!_c.isAnimating && _c.value == 0) {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  /// Deterministic scatter for piece [i]: a tilt within ±12° (never flat)
  /// and an offset within ±40 px.
  static (double, Offset) _scatter(int i) {
    var deg = (i * 37 % 25) - 12;
    if (deg == 0) deg = 7;
    final dx = ((i * 53 % 81) - 40).toDouble();
    final dy = ((i * 29 % 81) - 40).toDouble();
    return (deg * math.pi / 180, Offset(dx, dy));
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final n = widget.pieces.length;
    final total = _c.duration!.inMicroseconds;
    final settle = (ds.motion.slow * 2).inMicroseconds;

    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: ds.space.s,
      mainAxisSpacing: ds.space.s,
      children: [
        for (var i = 0; i < n; i++)
          AnimatedBuilder(
            animation: _c,
            builder: (_, child) {
              final start = (DsCollage.stagger * i).inMicroseconds / total;
              final end = math.min(1.0, start + settle / total);
              final t = Interval(
                start,
                end,
                curve: Curves.easeOutBack,
              ).transform(_c.value);
              final (angle, offset) = _scatter(i);
              return Transform(
                key: DsCollage.pieceKey,
                alignment: Alignment.center,
                transform: Matrix4.translationValues(
                  offset.dx * (1 - t),
                  offset.dy * (1 - t),
                  0,
                )..rotateZ(angle * (1 - t)),
                child: child,
              );
            },
            child: ClipRRect(
              borderRadius: ds.shape.cardRadius,
              child: widget.pieces[i],
            ),
          ),
      ],
    );
  }
}
