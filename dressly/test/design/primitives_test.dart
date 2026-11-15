import 'package:dressly/design/ds.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/ds_harness.dart';

void main() {
  setUpAll(loadDsFonts);

  testWidgets('DsButton calls onPressed', (t) async {
    var taps = 0;
    await t.pumpWidget(dsFrame(DsButton(label: 'Go', onPressed: () => taps++)));
    await t.tap(find.text('Go'));
    expect(taps, 1);
  });

  testWidgets('disabled DsButton ignores taps', (t) async {
    await t.pumpWidget(dsFrame(const DsButton(label: 'Go', onPressed: null)));
    await t.tap(find.text('Go'), warnIfMissed: false);
    expect(t.takeException(), isNull);
  });

  testWidgets('loading DsButton ignores taps and shows a progress indicator', (
    t,
  ) async {
    var taps = 0;
    await t.pumpWidget(
      dsFrame(DsButton(label: 'Go', loading: true, onPressed: () => taps++)),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await t.tap(find.byType(DsButton));
    expect(taps, 0);
  });

  testWidgets('DsButton.icon exposes its semantic label', (t) async {
    await t.pumpWidget(
      dsFrame(
        DsButton.icon(
          icon: Icons.refresh,
          semanticLabel: 'Autre',
          onPressed: () {},
        ),
      ),
    );
    expect(find.bySemanticsLabel('Autre'), findsOneWidget);
  });

  testWidgets('DsChip calls onTap', (t) async {
    var taps = 0;
    await t.pumpWidget(
      dsFrame(DsChip(label: 'Hoodies', selected: false, onTap: () => taps++)),
    );
    await t.tap(find.text('Hoodies'));
    expect(taps, 1);
  });

  testWidgets('DsSegment reports the tapped value', (t) async {
    int? got;
    await t.pumpWidget(
      dsFrame(
        DsSegment<int>(
          options: const [(0, 'Tout'), (1, 'Bas'), (2, 'Sneakers')],
          value: 0,
          onChanged: (v) => got = v,
        ),
      ),
    );
    await t.tap(find.text('Bas'));
    expect(got, 1);
  });

  testWidgets('primitives do not overflow at text scale 1.6', (t) async {
    await t.pumpWidget(dsFrame(_all(), width: 360, textScale: 1.6));
    expect(t.takeException(), isNull);
  });

  group('goldens', () {
    testWidgets('button_primary', (t) async {
      await expectDsGolden(
        t,
        DsButton(label: 'Je mets ça', onPressed: () {}, expand: true),
        'button_primary',
        height: 90,
      );
    });
    testWidgets('button_secondary', (t) async {
      await expectDsGolden(
        t,
        DsButton(
          label: 'Autre',
          icon: Icons.refresh,
          kind: DsButtonKind.secondary,
          onPressed: () {},
        ),
        'button_secondary',
        height: 90,
      );
    });
    testWidgets('button_icon', (t) async {
      await expectDsGolden(
        t,
        DsButton.icon(
          icon: Icons.refresh,
          semanticLabel: 'Autre',
          onPressed: () {},
        ),
        'button_icon',
        height: 90,
      );
    });
    testWidgets('chip_states', (t) async {
      await expectDsGolden(
        t,
        Row(
          children: [
            DsChip(label: 'Tout', selected: true, onTap: () {}),
            const SizedBox(width: 8),
            DsChip(label: 'Hoodies', selected: false, onTap: () {}),
          ],
        ),
        'chip_states',
        height: 80,
      );
    });
    testWidgets('segment', (t) async {
      await expectDsGolden(t, _segment(), 'segment', height: 80);
    });
    testWidgets('badges', (t) async {
      await expectDsGolden(
        t,
        const Row(
          children: [
            DsBadge(text: 'top'),
            SizedBox(width: 8),
            DsBadge(text: 'dort', tone: DsBadgeTone.accent),
          ],
        ),
        'badges',
        height: 60,
      );
    });
  });
}

Widget _segment() => DsSegment<int>(
  options: const [
    (0, 'Tout'),
    (1, 'Hoodies'),
    (2, 'Bas'),
    (3, 'Sneakers'),
    (4, 'Vestes'),
  ],
  value: 0,
  onChanged: (_) {},
);

Widget _all() => Column(
  mainAxisSize: MainAxisSize.min,
  crossAxisAlignment: CrossAxisAlignment.start,
  children: [
    DsButton(label: 'Je mets ça', onPressed: () {}, expand: true),
    const SizedBox(height: 8),
    DsButton(
      label: 'Autre tenue',
      icon: Icons.refresh,
      kind: DsButtonKind.secondary,
      onPressed: () {},
    ),
    const SizedBox(height: 8),
    _segment(),
    const SizedBox(height: 8),
    const DsBadge(text: 'dort', tone: DsBadgeTone.accent),
  ],
);
