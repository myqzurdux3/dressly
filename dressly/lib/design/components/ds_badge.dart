import 'package:flutter/material.dart';

import '../ds.dart';

enum DsBadgeTone { neutral, accent }

/// Small mono label stuck on a card, like a stock tag ("TOP", "DORT").
/// The neutral badge is cream on ink in both themes: it sits on garment
/// colours, not on the page.
class DsBadge extends StatelessWidget {
  const DsBadge({
    super.key,
    required this.text,
    this.tone = DsBadgeTone.neutral,
  });

  final String text;
  final DsBadgeTone tone;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final (fill, ink) = switch (tone) {
      DsBadgeTone.neutral => (ThemeF.ink, ThemeF.cream),
      DsBadgeTone.accent => (ds.colors.accent, ds.colors.onAccent),
    };
    return DecoratedBox(
      decoration: BoxDecoration(color: fill, borderRadius: ds.shape.pillRadius),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: ds.space.s, vertical: 3),
        child: Text(
          text.toUpperCase(),
          maxLines: 1,
          style: ds.typo.monoSmall.copyWith(color: ink),
        ),
      ),
    );
  }
}
