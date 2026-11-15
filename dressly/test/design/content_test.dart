import 'package:dressly/design/ds.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/contrast.dart';
import '../support/ds_harness.dart';

Widget _img(GarmentTone t) => Icon(Icons.checkroom, size: 80, color: t.shade);

DsSwatchCard _card(
  String color,
  String name, {
  String? badge,
  Widget? trailing,
  VoidCallback? onTap,
}) {
  final tone = garmentTone(color, Brightness.dark);
  return DsSwatchCard(
    image: _img(tone),
    name: name,
    subtitle: '14× porté',
    tone: tone,
    badge: badge,
    trailing: trailing,
    onTap: onTap ?? () {},
  );
}

Widget _grid() => SizedBox(
  width: 388,
  child: GridView.count(
    crossAxisCount: 2,
    shrinkWrap: true,
    crossAxisSpacing: 8,
    mainAxisSpacing: 8,
    childAspectRatio: DsSwatchCard.aspectRatio,
    children: [
      _card('Orange', 'Hoodie orange', badge: 'top'),
      _card('Green', 'Cargo kaki'),
      _card('Beige', 'Runners crème'),
      _card('Black', 'Doudoune noire', badge: 'dort'),
    ],
  ),
);

final _days = [
  for (var i = 0; i < 5; i++)
    DsDay(
      date: DateTime(2026, 11, 13 + i),
      weekday: const ['jeu', 'ven', 'sam', 'dim', 'lun'][i],
      hasPlan: i != 3,
    ),
];

void main() {
  setUpAll(loadDsFonts);

  testWidgets('swatch card ellipsizes a 60-character unbroken name', (t) async {
    await t.pumpWidget(
      dsFrame(
        SizedBox(
          width: 180,
          child: AspectRatio(
            aspectRatio: DsSwatchCard.aspectRatio,
            child: _card('Blue', 'x' * 60),
          ),
        ),
      ),
    );
    expect(t.takeException(), isNull);
  });

  testWidgets('swatch card shows badge and trailing and reports taps', (
    t,
  ) async {
    var taps = 0;
    await t.pumpWidget(
      dsFrame(
        SizedBox(
          width: 180,
          child: AspectRatio(
            aspectRatio: DsSwatchCard.aspectRatio,
            child: _card(
              'Red',
              'Tee',
              badge: 'top',
              trailing: const Icon(Icons.favorite),
              onTap: () => taps++,
            ),
          ),
        ),
      ),
    );
    expect(find.text('TOP'), findsOneWidget);
    expect(find.byIcon(Icons.favorite), findsOneWidget);
    await t.tap(find.text('Tee'));
    await t.pump(const Duration(milliseconds: 400));
    expect(taps, 1);
  });

  double scaleOf(WidgetTester t) {
    final tr = t.widget<Transform>(
      find.descendant(
        of: find.byType(DsPressable),
        matching: find.byType(Transform),
      ),
    );
    return tr.transform.storage[0]; // x scale (max-axis includes z = 1)
  }

  testWidgets('DsPressable scales on press', (t) async {
    await t.pumpWidget(
      dsFrame(
        DsPressable(
          onTap: () {},
          child: const SizedBox(width: 100, height: 100),
        ),
      ),
    );
    final g = await t.startGesture(t.getCenter(find.byType(DsPressable)));
    await t.pump(); // starts the spring's ticker
    await t.pump(const Duration(milliseconds: 80));
    expect(scaleOf(t), lessThan(1));
    await g.up();
    await t.pumpAndSettle();
    expect(scaleOf(t), closeTo(1, 0.001));
  });

  testWidgets('DsPressable does not scale with animations disabled', (t) async {
    await t.pumpWidget(
      dsFrame(
        DsPressable(
          onTap: () {},
          child: const SizedBox(width: 100, height: 100),
        ),
        disableAnimations: true,
      ),
    );
    final g = await t.startGesture(t.getCenter(find.byType(DsPressable)));
    await t.pump(const Duration(milliseconds: 80));
    expect(scaleOf(t), 1);
    await g.up();
  });

  testWidgets('neutral badge on a swatch is readable on dark garments', (
    t,
  ) async {
    final black = garmentTone('Black', Brightness.dark);
    await t.pumpWidget(dsFrame(DsBadge(text: 'dort', on: black)));
    final box = t.widget<DecoratedBox>(
      find.descendant(
        of: find.byType(DsBadge),
        matching: find.byType(DecoratedBox),
      ),
    );
    final fill = (box.decoration as BoxDecoration).color!;
    final ink = t.widget<Text>(find.text('DORT')).style!.color!;
    expect(contrast(ink, fill), greaterThanOrEqualTo(4.5));
    expect(contrast(fill, black.fill), greaterThanOrEqualTo(3));
  });

  testWidgets('DsDayStrip reports the tapped date', (t) async {
    DateTime? got;
    await t.pumpWidget(
      dsFrame(
        DsDayStrip(
          days: _days,
          selected: _days[2].date,
          onSelect: (d) => got = d,
        ),
      ),
    );
    await t.tap(find.text('16'));
    expect(got, DateTime(2026, 11, 16));
  });

  testWidgets('plan card with no thumbs shows the add affordance', (t) async {
    await t.pumpWidget(
      dsFrame(
        DsPlanCard(
          title: 'Dimanche',
          subtitle: 'rien de prévu',
          thumbs: const [],
          onTap: () {},
        ),
      ),
    );
    expect(find.byIcon(Icons.add), findsOneWidget);
  });

  group('goldens', () {
    testWidgets('swatch_grid', (t) async {
      await expectDsGolden(t, _grid(), 'swatch_grid', height: 520);
    });
    testWidgets('swatch_long_name', (t) async {
      await expectDsGolden(
        t,
        SizedBox(
          width: 190,
          child: AspectRatio(
            aspectRatio: DsSwatchCard.aspectRatio,
            child: _card(
              'Purple',
              'Veste de survêtement vintage oversize violette brodée',
            ),
          ),
        ),
        'swatch_long_name',
        height: 260,
      );
    });
    testWidgets('day_strip', (t) async {
      await expectDsGolden(
        t,
        DsDayStrip(days: _days, selected: _days[2].date, onSelect: (_) {}),
        'day_strip',
        height: 110,
      );
    });
    testWidgets('plan_cards', (t) async {
      final o = garmentTone('Orange', Brightness.dark);
      await expectDsGolden(
        t,
        Column(
          children: [
            DsPlanCard(
              title: 'Bureau',
              subtitle: "aujourd'hui · 9°",
              tone: o,
              thumbs: [_img(o), _img(garmentTone('Black', Brightness.dark))],
              onTap: () {},
            ),
            const SizedBox(height: 8),
            DsPlanCard(
              title: 'Dimanche',
              subtitle: 'rien de prévu · 8°',
              thumbs: const [],
              onTap: () {},
            ),
          ],
        ),
        'plan_cards',
        height: 200,
      );
    });
    testWidgets('layer_rows', (t) async {
      Widget row(String i, String c, String n, String note) => DsLayerRow(
        index: i,
        image: _img(garmentTone(c, Brightness.dark)),
        name: n,
        note: note,
      );
      await expectDsGolden(
        t,
        Column(
          children: [
            row('L3·ext', 'Black', 'Doudoune noire', 'imperméable'),
            row('L2·mid', 'Grey', 'Hoodie gris', 'chaleur'),
            row('bas', 'Green', 'Cargo kaki', 'ripstop'),
            row('pieds', 'White', 'Trail blanches', 'grip mouillé'),
          ],
        ),
        'layer_rows',
        height: 300,
      );
    });
  });
}
