import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dressly/widgets/brand_logo.dart';

Widget _wrap(Widget child, [Brightness brightness = Brightness.dark]) =>
    MaterialApp(
      // Built the same way the app builds its themes (ThemeController.themeFor):
      // a bare ThemeData(brightness:) does not carry through to Theme.of().
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF14B8A6),
          brightness: brightness,
        ),
      ),
      home: Scaffold(body: Center(child: child)),
    );

TextStyle _styleOf(WidgetTester tester, Finder of) => tester
    .widget<Text>(find.descendant(of: of, matching: find.byType(Text)))
    .style!;

/// The dot is the only circle in the mark; the tile is a rounded rectangle.
Finder _dot(Finder of) => find.descendant(
      of: of,
      matching: find.byWidgetPredicate((w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).shape == BoxShape.circle),
    );

void main() {
  group('DresslyWordmark', () {
    testWidgets('draws the wordmark in the brand grotesque', (tester) async {
      await tester.pumpWidget(_wrap(const DresslyWordmark()));
      expect(find.text('dressly'), findsOneWidget);
      final style = _styleOf(tester, find.byType(DresslyWordmark));
      expect(style.fontFamily, 'Manrope');
      expect(style.fontWeight, FontWeight.w800);
    });

    testWidgets('compact is the app-bar form, not just a smaller one',
        (tester) async {
      await tester.pumpWidget(_wrap(const DresslyWordmark(compact: true)));
      expect(find.text('Dressly'), findsOneWidget);
      final style = _styleOf(tester, find.byType(DresslyWordmark));
      expect(style.fontWeight, FontWeight.w700);
      // Looser tracking: the display tightening closes up at small sizes.
      expect(style.letterSpacing, greaterThan(28 * -0.045));
    });

    testWidgets('flips with the surface brightness so it stays readable',
        (tester) async {
      await tester.pumpWidget(_wrap(const DresslyWordmark()));
      expect(_styleOf(tester, find.byType(DresslyWordmark)).color,
          BrandColors.light);

      await tester.pumpWidget(_wrap(const DresslyWordmark(), Brightness.light));
      // MaterialApp lerps between themes; let the swap finish.
      await tester.pumpAndSettle();
      expect(_styleOf(tester, find.byType(DresslyWordmark)).color,
          BrandColors.dark);
    });

    testWidgets('honours an explicit color override', (tester) async {
      await tester
          .pumpWidget(_wrap(const DresslyWordmark(color: Colors.green)));
      expect(
          _styleOf(tester, find.byType(DresslyWordmark)).color, Colors.green);
    });
  });

  group('DresslyMonogram', () {
    testWidgets('is a rounded tile holding an extra-bold d', (tester) async {
      await tester.pumpWidget(_wrap(const DresslyMonogram(size: 86)));
      expect(tester.getSize(find.byType(DresslyMonogram)), const Size(86, 86));

      final tile = tester.widget<Container>(find.descendant(
        of: find.byType(DresslyMonogram),
        matching: find.byWidgetPredicate((w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).borderRadius != null),
      ));
      final decoration = tile.decoration as BoxDecoration;
      expect(decoration.color, BrandColors.tile);
      expect(decoration.borderRadius,
          BorderRadius.circular(86 * 0.302)); // artboard radius

      final style = _styleOf(tester, find.byType(DresslyMonogram));
      expect(style.fontFamily, 'Manrope');
      expect(style.fontWeight, FontWeight.w800);
      expect(style.fontSize, closeTo(49.97, 0.01)); // 50px inside 86px
      expect(style.color, BrandColors.light);
    });

    testWidgets('keeps the dot mint, not the theme accent', (tester) async {
      // The user can repaint the app from Settings; the logo must not follow.
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFEC4899)),
        ),
        home: const Scaffold(body: DresslyMonogram()),
      ));
      final dot = tester.widget<Container>(_dot(find.byType(DresslyMonogram)));
      expect((dot.decoration as BoxDecoration).color, BrandColors.mint);
    });

    testWidgets('scales the dot with the tile', (tester) async {
      await tester.pumpWidget(_wrap(const DresslyMonogram(size: 100)));
      expect(tester.getSize(_dot(find.byType(DresslyMonogram))).width,
          closeTo(10.5, 0.01));
    });

    testWidgets('drops the dot at small sizes, where it only muddies the tile',
        (tester) async {
      await tester.pumpWidget(_wrap(const DresslyMonogram(size: 34)));
      expect(_dot(find.byType(DresslyMonogram)), findsOneWidget);

      await tester.pumpWidget(_wrap(const DresslyMonogram(size: 20)));
      expect(_dot(find.byType(DresslyMonogram)), findsNothing);
    });

    testWidgets('showDot overrides the size rule in both directions',
        (tester) async {
      await tester
          .pumpWidget(_wrap(const DresslyMonogram(size: 20, showDot: true)));
      expect(_dot(find.byType(DresslyMonogram)), findsOneWidget);

      await tester
          .pumpWidget(_wrap(const DresslyMonogram(size: 86, showDot: false)));
      expect(_dot(find.byType(DresslyMonogram)), findsNothing);
    });
  });

  group('DresslyLockup', () {
    testWidgets('pairs the tile and the wordmark', (tester) async {
      await tester.pumpWidget(_wrap(
        const DresslyLockup(tileSize: 34, wordmarkSize: 21, compact: true),
      ));
      expect(find.byType(DresslyMonogram), findsOneWidget);
      expect(find.text('Dressly'), findsOneWidget);
      expect(tester.getSize(find.byType(DresslyMonogram)), const Size(34, 34));
    });
  });
}
