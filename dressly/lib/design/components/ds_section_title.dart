import 'package:flutter/material.dart';

import '../ds.dart';

/// Small mono heading over a block of a screen, with an optional hint line.
class DsSectionTitle extends StatelessWidget {
  const DsSectionTitle(this.text, {super.key, this.hint});

  final String text;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Padding(
      padding: EdgeInsets.only(top: ds.space.l, bottom: ds.space.s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            text.toUpperCase(),
            style: ds.typo.mono.copyWith(color: ds.colors.textMuted),
          ),
          if (hint != null) ...[
            SizedBox(height: ds.space.xs),
            Text(
              hint!,
              style: ds.typo.label.copyWith(color: ds.colors.textMuted),
            ),
          ],
        ],
      ),
    );
  }
}
