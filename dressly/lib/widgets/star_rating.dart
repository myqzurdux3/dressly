import 'package:flutter/material.dart';

import '../l10n/app_text.dart';
import '../theme/tones.dart';

/// Tap-to-rate stars. Pass the current score (0..5); 0 = unrated. Calls
/// onChanged when the user picks a new value (0 when tapping the current
/// rating again, to clear the rating).
class StarRating extends StatelessWidget {
  const StarRating({super.key, required this.score, required this.onChanged});
  final int score;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 1; i <= 5; i++)
          IconButton(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.all(2),
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            iconSize: 28,
            tooltip: '$i / 5',
            icon: Icon(
              i <= score ? Icons.star : Icons.star_border,
              color: i <= score ? Colors.amber : faintText(context),
            ),
            onPressed: () => onChanged(i == score ? 0 : i),
          ),
        if (score == 0)
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text(tr(context, 'star.notRated'),
                style: const TextStyle(color: Colors.grey)),
          ),
      ],
    );
  }
}