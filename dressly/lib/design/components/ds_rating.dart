import 'package:flutter/material.dart';

import '../ds.dart';

/// Tap-to-rate, 1 to 5. Tapping the current value again reports 0 (clears).
class DsRating extends StatelessWidget {
  const DsRating({super.key, required this.score, required this.onChanged});

  /// 0 = unrated.
  final int score;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.ds.colors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 1; i <= 5; i++)
          Semantics(
            button: true,
            selected: i <= score,
            label: '$i / 5',
            excludeSemantics: true,
            child: SizedBox.square(
              dimension: 44,
              child: IconButton(
                padding: EdgeInsets.zero,
                onPressed: () => onChanged(i == score ? 0 : i),
                icon: Icon(
                  i <= score ? Icons.star_rounded : Icons.star_outline_rounded,
                  size: 30,
                  color: i <= score ? c.accent : c.textMuted,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
