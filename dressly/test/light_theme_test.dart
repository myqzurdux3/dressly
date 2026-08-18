import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dressly/models/cloth.dart';
import 'package:dressly/theme/tones.dart';
import 'package:dressly/widgets/cloth_card.dart';
import 'package:dressly/widgets/star_rating.dart';

/// The light theme has to be readable.
///
/// The app was written dark-first and its secondary text was literal
/// `Colors.white70` / `white54` / `white60`. Every one of those disappears on a
/// white page — brand names, tags, the wardrobe counter and the category chips
/// were invisible in light mode, which no dark-mode screenshot could show.
///
/// The rule these tests encode: text drawn on the PAGE follows the theme; text
/// drawn on a PHOTO stays white on purpose.

/// WCAG relative luminance.
double _luminance(Color c) {
  double channel(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}

double _contrast(Color a, Color b) {
  final la = _luminance(a), lb = _luminance(b);
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

Cloth _cloth() => Cloth(
      id: 1,
      userId: 1,
      name: 'Blue tee',
      brand: 'UNIQLO',
      cut: 'normal',
      category: 'tshirt',
      customTags: const ['summer'],
      colors: const [],
      images: const [],
      score: 2,
    );

Widget _app(Brightness brightness, Widget child, {double width = 200}) =>
    MaterialApp(
      locale: const Locale('en'),
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF14B8A6),
          brightness: brightness,
        ),
      ),
      home:
          Scaffold(body: Center(child: SizedBox(width: width, child: child))),
    );

/// The colour a Text actually renders with.
Color _colorOf(WidgetTester tester, String text) =>
    tester.widget<Text>(find.text(text)).style!.color!;

void main() {
  for (final brightness in [Brightness.light, Brightness.dark]) {
    final name = brightness == Brightness.light ? 'light' : 'dark';

    testWidgets('card text stays legible in $name', (tester) async {
      await tester.pumpWidget(_app(
          brightness, ClothCard(cloth: _cloth(), onTap: () {})));
      await tester.pump();

      final background = tester
          .widget<Material>(find.byType(Material).first)
          .color ??
          Theme.of(tester.element(find.byType(ClothCard)))
              .colorScheme
              .surface;

      for (final text in ['UNIQLO', '#summer']) {
        expect(_contrast(_colorOf(tester, text), background), greaterThan(3.0),
            reason: '"$text" is unreadable on the $name background');
      }
    });

    testWidgets('a badge over the photo stays readable in $name',
        (tester) async {
      await tester
          .pumpWidget(_app(brightness, ClothCard(cloth: _cloth(), onTap: () {})));
      await tester.pump();

      // The rating badge sits on a fixed black54 disc over the photo. It has to
      // keep its own light colour: following the theme turned it dark-on-dark
      // and the number simply vanished in light mode.
      const scrim = Color(0xFF3F3F3F); // black54 over a mid-tone photo
      expect(_contrast(_colorOf(tester, '2'), scrim), greaterThan(4.5),
          reason: 'the rating badge is unreadable on its own scrim in $name');
    });

    testWidgets('an unrated star is visible in $name', (tester) async {
      await tester.pumpWidget(_app(
          brightness, StarRating(score: 0, onChanged: (_) {}),
          width: 400));
      await tester.pump();

      final scheme =
          Theme.of(tester.element(find.byType(StarRating))).colorScheme;
      final empty = tester
          .widgetList<Icon>(find.byIcon(Icons.star_border))
          .first
          .color!;
      expect(_contrast(empty, scheme.surface), greaterThan(1.6),
          reason: 'the empty stars vanish, so the rating reads as absent');
    });
  }

  testWidgets('the tones follow the theme rather than a fixed white',
      (tester) async {
    final colors = <Brightness, Color>{};
    for (final brightness in [Brightness.light, Brightness.dark]) {
      await tester.pumpWidget(_app(
          brightness,
          Builder(
              builder: (context) =>
                  Text('x', style: TextStyle(color: secondaryText(context))))));
      await tester.pumpAndSettle();
      colors[brightness] = _colorOf(tester, 'x');
    }
    expect(colors[Brightness.light], isNot(colors[Brightness.dark]),
        reason: 'a single hardcoded colour cannot suit both themes');
  });
}
