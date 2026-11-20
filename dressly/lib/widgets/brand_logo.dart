import 'package:flutter/material.dart';

import '../design/ds.dart';

/// The app's mark: the clothing tag of the launcher icon, same bitmap, so the
/// login screen and the home screen icon cannot drift apart.
class DresslyMark extends StatelessWidget {
  const DresslyMark({super.key, this.size = 96});

  final double size;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.22),
      child: Image.asset(
        'assets/brand/mark.png',
        width: size,
        height: size,
        cacheWidth:
            (size * (MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1))
                .round(),
        semanticLabel: 'Dressly',
      ),
    );
  }
}

/// Mark above the name, set like the screen headers (condensed capitals).
class DresslyLockup extends StatelessWidget {
  const DresslyLockup({super.key, this.markSize = 96});

  final double markSize;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        DresslyMark(size: markSize),
        SizedBox(height: ds.space.m),
        ExcludeSemantics(
          child: Text(
            'DRESSLY',
            style: ds.typo.display.copyWith(color: ds.colors.text),
          ),
        ),
      ],
    );
  }
}
