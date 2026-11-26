import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dressly/design/ds.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:dressly/models/outfit.dart';
import 'package:dressly/models/user.dart';
import 'package:dressly/screens/outfit/outfit_result_dialog.dart';
import 'package:dressly/services/pinned_http.dart';
import 'package:dressly/state/session.dart';

/// An outfit the week planner wrote holds the clothes for a day and no image.
///
/// The dialog used to call it "Generated outfit", draw a broken-image
/// placeholder, and offer Download, Share, "back view" and "try a better
/// model" — every one of which needs a render that does not exist. What it did
/// NOT offer was any way to produce one.

Map<String, dynamic> _outfit({String generatedUrl = '', String kind = 'plan'}) =>
    {
      'id': 42,
      'kind': kind,
      'model_id': null,
      'cloth_ids': [1],
      'cloths': <Map<String, dynamic>>[],
      'prompt': '',
      'generated_url': generatedUrl,
      'status': 'done',
      'model_tier': 'max',
      'created_at': '2026-08-18T10:00:00',
    };

void main() {
  late List<String> posted;

  Future<void> pump(WidgetTester tester, Map<String, dynamic> json) async {
    posted = [];
    PinnedHttp.setClientForTesting(MockClient((req) async {
      posted.add('${req.method} ${req.url.path}');
      return http.Response(jsonEncode(_outfit(generatedUrl: '/o/42.webp')), 200);
    }));
    final session = Session()
      ..setSession(AppUser(id: 1, email: 'a@b.co', isAdmin: false), 'tok');
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: session,
      child: MaterialApp(
        locale: const Locale('en'),
        theme: const ThemeF().themeData(Brightness.dark, DsAccent.orange),
        home: Scaffold(
          body: OutfitResultDialog(
              outfit: Outfit.fromJson(json), onChanged: (_) {}),
        ),
      ),
    ));
    await tester.pump();
  }

  tearDown(() => PinnedHttp.setClientForTesting(null));

  testWidgets('a planned day offers the render it is missing', (tester) async {
    await pump(tester, _outfit());

    expect(find.text('PLANNED OUTFIT'), findsOneWidget);
    expect(find.text('GENERATED OUTFIT'), findsNothing);
    expect(find.widgetWithText(DsButton, 'Generate the image'),
        findsOneWidget);
    // Actions that need an image are not shown at all, rather than shown and
    // failing on a file that was never written.
    expect(find.text('Download'), findsNothing);
    expect(find.text('Generate back view'), findsNothing);
    expect(find.textContaining('best model'), findsNothing);
  });

  testWidgets('pressing it asks the server to render this very outfit',
      (tester) async {
    await pump(tester, _outfit());

    await tester.tap(find.widgetWithText(DsButton, 'Generate the image'));
    await tester.pump();

    // Reads first (the collage loads the garments' pictures), one write.
    expect(posted.where((r) => !r.startsWith('GET ')),
        ['POST /outfits/42/regenerate']);
  });

  testWidgets('a rendered outfit keeps every image action', (tester) async {
    await pump(tester, _outfit(generatedUrl: '/o/42.webp', kind: 'ai'));

    expect(find.text('GENERATED OUTFIT'), findsOneWidget);
    expect(find.widgetWithText(DsButton, 'Generate the image'),
        findsNothing);
    expect(find.text('Download'), findsOneWidget);
  });

  testWidgets('secondary actions live in one "More actions" sheet', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(412, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pump(tester, _outfit(generatedUrl: '/o/42.webp', kind: 'ai'));

    // Main actions stay in the dialog; the secondary ones are not loose.
    expect(find.text('Download'), findsOneWidget);
    expect(find.text('Add to agenda'), findsNothing);

    await tester.tap(find.widgetWithText(DsButton, 'More actions'));
    // Pumped by hand: the image placeholder keeps a spinner going.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    final sheet = find.byType(BottomSheet);
    expect(sheet, findsOneWidget);
    for (final label in [
      'Wear history',
      'Generate back view',
      'Add to agenda',
      'Report problem to support',
      'Delete from history',
    ]) {
      expect(
        find.descendant(of: sheet, matching: find.text(label)),
        findsOneWidget,
        reason: label,
      );
    }
    expect(
      find.descendant(of: sheet, matching: find.byType(ListTile)),
      findsNWidgets(7),
    );
  });
}
