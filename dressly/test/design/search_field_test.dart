import 'package:dressly/design/ds.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/ds_harness.dart';

void main() {
  testWidgets("clear button empties the field and reports ''", (t) async {
    final c = TextEditingController(text: 'hood');
    final seen = <String>[];
    await t.pumpWidget(
      dsFrame(
        DsSearchField(
          controller: c,
          hint: 'Search',
          clearLabel: 'Clear',
          onChanged: seen.add,
        ),
      ),
    );
    await t.tap(find.bySemanticsLabel('Clear'));
    await t.pump();
    expect(c.text, '');
    expect(seen, ['']);
    expect(find.bySemanticsLabel('Clear'), findsNothing);
  });

  testWidgets('no clear button while empty', (t) async {
    await t.pumpWidget(
      dsFrame(
        DsSearchField(
          controller: TextEditingController(),
          hint: 'S',
          clearLabel: 'Clear',
        ),
      ),
    );
    expect(find.bySemanticsLabel('Clear'), findsNothing);
  });
}
