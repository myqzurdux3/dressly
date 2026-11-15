import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../ds.dart';

/// Nothing to show yet, with an optional way forward.
class DsEmpty extends StatelessWidget {
  const DsEmpty({
    super.key,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return _Centered(
      children: [
        Text(
          title.toUpperCase(),
          textAlign: TextAlign.center,
          style: ds.typo.headline,
        ),
        SizedBox(height: ds.space.s),
        Text(
          message,
          textAlign: TextAlign.center,
          style: ds.typo.body.copyWith(color: ds.colors.textMuted),
        ),
        if (actionLabel != null && onAction != null) ...[
          SizedBox(height: ds.space.xl),
          DsButton(label: actionLabel!, onPressed: onAction),
        ],
      ],
    );
  }
}

/// Something failed; say what and offer a retry.
class DsError extends StatelessWidget {
  const DsError({
    super.key,
    required this.message,
    required this.onRetry,
    required this.retryLabel,
  });

  final String message;
  final VoidCallback onRetry;
  final String retryLabel;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return _Centered(
      children: [
        Icon(Icons.wifi_off_rounded, size: 40, color: ds.colors.danger),
        SizedBox(height: ds.space.m),
        Text(message, textAlign: TextAlign.center, style: ds.typo.bodyStrong),
        SizedBox(height: ds.space.xl),
        DsButton(
          label: retryLabel,
          icon: Icons.refresh,
          kind: DsButtonKind.secondary,
          onPressed: onRetry,
        ),
      ],
    );
  }
}

class _Centered extends StatelessWidget {
  const _Centered({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(context.ds.space.xl),
        child: Column(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }
}

/// Placeholder block that breathes while content loads. Still when
/// animations are disabled.
class DsSkeleton extends StatefulWidget {
  const DsSkeleton({
    super.key,
    required double this.width,
    required double this.height,
    this.radius,
  }) : gridCount = null;

  /// Placeholders shaped like a two-column grid of swatch cards.
  const DsSkeleton.swatchGrid({super.key, int count = 4})
    : gridCount = count,
      width = null,
      height = null,
      radius = null;

  final double? width;
  final double? height;
  final double? radius;
  final int? gridCount;

  @override
  State<DsSkeleton> createState() => _DsSkeletonState();
}

class _DsSkeletonState extends State<DsSkeleton>
    with SingleTickerProviderStateMixin {
  AnimationController? _c;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.gridCount != null) return; // children animate themselves
    if (MediaQuery.disableAnimationsOf(context)) {
      _c?.dispose();
      _c = null;
    } else {
      _c ??= AnimationController(
        vsync: this,
        duration: context.ds.motion.slow * 4,
      )..repeat();
    }
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final count = widget.gridCount;
    if (count != null) {
      return GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        crossAxisSpacing: ds.space.s,
        mainAxisSpacing: ds.space.s,
        childAspectRatio: DsSwatchCard.aspectRatio,
        children: [
          for (var i = 0; i < count; i++)
            DsSkeleton(
              width: double.infinity,
              height: double.infinity,
              radius: ds.shape.card,
            ),
        ],
      );
    }

    Widget block(double t) => Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        color: Color.lerp(ds.colors.surface, ds.colors.surfaceHigh, t),
        borderRadius: BorderRadius.circular(widget.radius ?? ds.shape.small),
      ),
    );

    final c = _c;
    if (c == null) return block(0.5);
    return AnimatedBuilder(
      animation: c,
      builder: (_, _) => block((math.sin(c.value * 2 * math.pi) + 1) / 2),
    );
  }
}
