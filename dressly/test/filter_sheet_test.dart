import 'package:dressly/services/clothes_service.dart';
import 'package:dressly/widgets/filter_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Favourites-only lives on the app bar heart, not in this sheet, so the sheet
/// has to hand it back untouched — otherwise applying any filter turns it off
/// while the heart stays lit.

Future<ClothFilter?> _applyOn(WidgetTester tester, ClothFilter initial) async {
  ClothFilter? applied;
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async {
            applied = await showModalBottomSheet<ClothFilter>(
              context: context,
              isScrollControlled: true,
              builder: (_) => FilterSheet(
                filter: initial,
                availableBrands: const [],
                availableTags: const [],
              ),
            );
          },
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  // The sheet is taller than the test viewport; Apply sits below the fold.
  await tester.ensureVisible(find.text('Apply'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Apply'));
  await tester.pumpAndSettle();
  return applied;
}

void main() {
  testWidgets('applying a filter keeps favourites-only on', (tester) async {
    final out = await _applyOn(
        tester, ClothFilter(favorite: true, sort: 'newest'));

    expect(out, isNotNull);
    expect(out!.favorite, isTrue);
  });

  testWidgets('applying a filter does not switch favourites-only on',
      (tester) async {
    final out = await _applyOn(tester, ClothFilter(sort: 'newest'));

    expect(out!.favorite, isFalse);
  });
}
