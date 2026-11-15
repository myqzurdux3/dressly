import 'package:dressly/design/ds.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/ds_harness.dart';

const _items = [
  DsTabItem(icon: Icons.checkroom, label: 'Stock'),
  DsTabItem(icon: Icons.auto_awesome, label: 'Fit'),
  DsTabItem(icon: Icons.calendar_month, label: 'Semaine'),
  DsTabItem(icon: Icons.favorite, label: 'Sauvés'),
  DsTabItem(icon: Icons.person, label: 'Moi'),
];

Widget _header() => const DsHeader(
  line1: 'Ma',
  line2: 'drip',
  meta: ['87 pièces', '+3 ce mois'],
);

DsTabBar _bar(int index, [ValueChanged<int>? onTap]) =>
    DsTabBar(items: _items, index: index, onTap: onTap ?? (_) {});

void main() {
  setUpAll(loadDsFonts);

  testWidgets('DsHeader uppercases both lines and shows meta', (t) async {
    await t.pumpWidget(dsFrame(_header()));
    expect(find.text('MA'), findsOneWidget);
    expect(find.text('DRIP'), findsOneWidget);
    expect(find.text('87 PIÈCES'), findsOneWidget);
    expect(find.text('+3 CE MOIS'), findsOneWidget);
  });

  testWidgets('DsTabBar reports the tapped index', (t) async {
    int? got;
    await t.pumpWidget(dsFrame(_bar(0, (i) => got = i)));
    await t.tap(find.byIcon(Icons.calendar_month));
    expect(got, 2);
  });

  testWidgets('inactive tabs expose their label to semantics', (t) async {
    await t.pumpWidget(dsFrame(_bar(0)));
    expect(find.bySemanticsLabel('Semaine'), findsOneWidget);
    expect(find.text('Stock'), findsOneWidget);
  });

  testWidgets('header and tab bar do not overflow at text scale 1.6', (
    t,
  ) async {
    await t.pumpWidget(
      dsFrame(
        Column(mainAxisSize: MainAxisSize.min, children: [_header(), _bar(2)]),
        width: 360,
        textScale: 1.6,
      ),
    );
    await t.pump(const Duration(seconds: 1));
    expect(t.takeException(), isNull);
  });

  testWidgets('DsScaffold.bottomInset clears the tab bar', (t) async {
    late double inset;
    await t.pumpWidget(
      dsFrame(
        Builder(
          builder: (c) {
            inset = DsScaffold.bottomInset(c);
            return _bar(0);
          },
        ),
      ),
    );
    final barHeight = t.getSize(find.byType(DsTabBar)).height;
    expect(inset, greaterThanOrEqualTo(barHeight + 16));
  });

  testWidgets('DsScaffold keeps body content above the floating tab bar', (
    t,
  ) async {
    await t.pumpWidget(
      MaterialApp(
        theme: const ThemeF().themeData(Brightness.dark, DsAccent.orange),
        home: DsScaffold(
          tabBar: _bar(0),
          body: Builder(
            builder: (c) => ListView(
              padding: EdgeInsets.only(bottom: DsScaffold.bottomInset(c)),
              children: [for (var i = 0; i < 30; i++) Text('row $i')],
            ),
          ),
        ),
      ),
    );
    // Scroll to the very end: the last row must rest above the bar.
    await t.drag(find.byType(ListView), const Offset(0, -5000));
    await t.pumpAndSettle();
    final last = t.getRect(find.text('row 29'));
    final bar = t.getRect(find.byType(DsTabBar));
    expect(last.bottom, lessThanOrEqualTo(bar.top));
  });

  group('goldens', () {
    testWidgets('header', (t) async {
      await expectDsGolden(t, _header(), 'header', height: 150);
    });
    testWidgets('tab_bar', (t) async {
      await expectDsGolden(t, _bar(0), 'tab_bar', height: 100);
    });
    testWidgets('tab_bar_index2', (t) async {
      await expectDsGolden(t, _bar(2), 'tab_bar_index2', height: 100);
    });
  });
}
