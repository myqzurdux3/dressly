import 'package:dressly/design/ds.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/ds_harness.dart';

void main() {
  setUpAll(loadDsFonts);

  testWidgets('tapping a star sets it, tapping the current one clears', (
    t,
  ) async {
    final got = <int>[];
    await t.pumpWidget(dsFrame(DsRating(score: 3, onChanged: got.add)));
    await t.tap(find.bySemanticsLabel('5 / 5'));
    await t.tap(find.bySemanticsLabel('3 / 5'));
    expect(got, [5, 0]);
  });

  testWidgets('filled stars match the score', (t) async {
    await t.pumpWidget(dsFrame(DsRating(score: 2, onChanged: (_) {})));
    expect(find.byIcon(Icons.star_rounded), findsNWidgets(2));
    expect(find.byIcon(Icons.star_outline_rounded), findsNWidgets(3));
  });

  testWidgets('golden', (t) async {
    await expectDsGolden(
      t,
      DsRating(score: 3, onChanged: (_) {}),
      'rating',
      height: 60,
    );
  });
}
