import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dressly/design/ds.dart';
import 'package:dressly/models/outfit.dart';
import 'package:dressly/widgets/outfit_history_card.dart';

/// An outfit whose AI picture is still being made has no image URL yet. Its
/// card used to load that empty URL and show a broken-image glyph; it must
/// show a spinner over the garments instead.
void main() {
  testWidgets('a rendering outfit shows a spinner, not a broken image', (
    tester,
  ) async {
    final o = Outfit.fromJson({
      'id': 5,
      'status': 'processing',
      'cloth_ids': [1],
      'cloths': [
        {'id': 1, 'name': 'tee', 'brand': '', 'thumb_url': ''},
      ],
    });
    expect(o.isProcessing, isTrue);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        theme: const ThemeF().themeData(Brightness.dark, DsAccent.orange),
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 400,
            child: OutfitHistoryCard(
              outfit: o,
              onTap: () {},
              onToggleFavorite: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Rendering…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byIcon(Icons.broken_image), findsNothing);
  });
}
