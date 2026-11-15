import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dressly/theme/tones.dart';
import 'package:dressly/widgets/star_rating.dart';

import 'support/contrast.dart';

/// The light theme has to be readable.
///
/// The app was written dark-first and its secondary text was literal
/// `Colors.white70` / `white54` / `white60`. Every one of those disappears on a
/// white page — brand names, tags, the wardrobe counter and the category chips
/// were invisible in light mode, which no dark-mode screenshot could show.
///
/// The rule these tests encode: text drawn on the PAGE follows the theme; text
/// drawn on a PHOTO stays white on purpose.

Widget _app(Brightness brightness, Widget child, {double width = 200}) =>
    MaterialApp(
      locale: const Locale('en'),
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF14B8A6),
          brightness: brightness,
        ),
      ),
      home: Scaffold(
        body: Center(
          child: SizedBox(width: width, child: child),
        ),
      ),
    );

/// The colour a Text actually renders with.
Color _colorOf(WidgetTester tester, String text) =>
    tester.widget<Text>(find.text(text)).style!.color!;

void main() {
  for (final brightness in [Brightness.light, Brightness.dark]) {
    final name = brightness == Brightness.light ? 'light' : 'dark';

    // ClothCard's two contrast tests left with the widget: WardrobeCard is a
    // DsSwatchCard, whose text contrast is checked in test/design/content_test.dart.

    testWidgets('an unrated star is visible in $name', (tester) async {
      await tester.pumpWidget(
        _app(brightness, StarRating(score: 0, onChanged: (_) {}), width: 400),
      );
      await tester.pump();

      final scheme = Theme.of(
        tester.element(find.byType(StarRating)),
      ).colorScheme;
      final empty = tester
          .widgetList<Icon>(find.byIcon(Icons.star_border))
          .first
          .color!;
      expect(
        contrast(empty, scheme.surface),
        greaterThan(1.6),
        reason: 'the empty stars vanish, so the rating reads as absent',
      );
    });
  }

  testWidgets('the tones follow the theme rather than a fixed white', (
    tester,
  ) async {
    final colors = <Brightness, Color>{};
    for (final brightness in [Brightness.light, Brightness.dark]) {
      await tester.pumpWidget(
        _app(
          brightness,
          Builder(
            builder: (context) =>
                Text('x', style: TextStyle(color: secondaryText(context))),
          ),
        ),
      );
      await tester.pumpAndSettle();
      colors[brightness] = _colorOf(tester, 'x');
    }
    expect(
      colors[Brightness.light],
      isNot(colors[Brightness.dark]),
      reason: 'a single hardcoded colour cannot suit both themes',
    );
  });
}
