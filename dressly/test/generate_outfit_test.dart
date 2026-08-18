import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:dressly/models/user.dart';
import 'package:dressly/screens/outfit/cloth_picker_screen.dart';
import 'package:dressly/screens/outfit/outfit_result_dialog.dart';
import 'package:dressly/screens/outfit/outfit_screen.dart';
import 'package:dressly/services/pinned_http.dart';
import 'package:dressly/state/gen_prefs_controller.dart';
import 'package:dressly/state/session.dart';

/// Generating an outfit: pick a garment, press generate, wait, see the result.
///
/// This is the screen where waiting is normal — a render takes tens of seconds
/// — so "nothing is happening" and "it failed silently" look identical to the
/// user. What is pinned here is that the wait is visible, that the result
/// arrives, and that a refusal is shown rather than swallowed.

Map<String, dynamic> _clothJson(int id, String name, String category) => {
      'id': id,
      'user_id': 1,
      'name': name,
      'brand': '',
      'cut': 'normal',
      'category': category,
      'custom_tags': <String>[],
      'colors': <Map<String, dynamic>>[],
      'score': 0,
      'images': <Map<String, dynamic>>[],
    };

Map<String, dynamic> _outfitJson({String status = 'done'}) => {
      'id': 42,
      'model_id': null,
      'cloth_ids': [1],
      'cloths': <Map<String, dynamic>>[],
      'prompt': '',
      'generated_url': status == 'done' ? '/media/outfits/42.webp' : '',
      'status': status,
      'model_tier': 'flex',
      'created_at': '2026-08-18T10:00:00',
    };

void main() {
  late List<http.BaseRequest> requests;
  late List<String> posted;

  /// Routes every call the screen makes. [generateResponse] answers
  /// POST /outfits/generate; [pollStatuses] are handed out one per
  /// GET /outfits/42, so a render can be made to take as long as the test
  /// needs it to.
  void serve({
    http.Response Function()? generateResponse,
    List<String> pollStatuses = const [],
  }) {
    final polls = List.of(pollStatuses);
    PinnedHttp.setClientForTesting(MockClient((req) async {
      requests.add(req);
      final path = req.url.path;
      if (path.endsWith('/models')) return http.Response('[]', 200);
      if (path.endsWith('/clothes')) {
        return http.Response(
            jsonEncode([
              _clothJson(1, 'Blue tee', 'tshirt'),
              _clothJson(2, 'Black jeans', 'jeans'),
            ]),
            200);
      }
      if (path.endsWith('/outfits') && req.method == 'GET') {
        return http.Response('[]', 200);
      }
      if (path.endsWith('/outfits/generate')) {
        posted.add(req.body);
        return (generateResponse ?? () => http.Response('{}', 500))();
      }
      if (path.endsWith('/outfits/42')) {
        final status = polls.isEmpty ? 'done' : polls.removeAt(0);
        return http.Response(jsonEncode(_outfitJson(status: status)), 200);
      }
      return http.Response('{}', 404);
    }));
  }

  setUp(() {
    requests = [];
    posted = [];
  });
  tearDown(() => PinnedHttp.setClientForTesting(null));

  Future<void> pump(WidgetTester tester) async {
    final session = Session()
      ..setSession(AppUser(id: 1, email: 'a@b.co', isAdmin: false), 'tok');
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: session),
        ChangeNotifierProvider(create: (_) => GenPrefsController()),
      ],
      child: const MaterialApp(
        locale: Locale('en'),
        home: OutfitScreen(),
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// Opens the picker, taps the first garment, confirms.
  Future<void> pickFirstCloth(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(OutlinedButton, 'Pick clothes'));
    await tester.pumpAndSettle();
    expect(find.byType(ClothPickerScreen), findsOneWidget);
    await tester.tap(find.text('Blue tee'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Done'));
    await tester.pumpAndSettle();
  }

  Future<void> tapGenerate(WidgetTester tester) async {
    // The button lives at the bottom of a lazy list: off a test-sized screen it
    // is not merely invisible, it is not built at all.
    final button = find.widgetWithText(FilledButton, 'Generate outfit');
    await tester.scrollUntilVisible(button, 300,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pump();
  }

  testWidgets('nothing selected: the app says so instead of asking the server',
      (tester) async {
    serve();
    await pump(tester);
    await tapGenerate(tester);
    await tester.pump(const Duration(milliseconds: 400));

    expect(
        find.descendant(
            of: find.byType(SnackBar),
            matching: find.text('Pick at least one cloth')),
        findsOneWidget);
    expect(posted, isEmpty, reason: 'a render bills real money');
  });

  testWidgets('the wait is visible, and the result opens by itself',
      (tester) async {
    serve(
      // The server accepts the job and renders in the background — the first
      // answer is not the picture.
      generateResponse: () =>
          http.Response(jsonEncode(_outfitJson(status: 'processing')), 200),
      pollStatuses: ['processing', 'done'],
    );
    await pump(tester);
    await pickFirstCloth(tester);
    await tapGenerate(tester);

    // Still rendering: the button says so and cannot be pressed again.
    expect(find.text('Generating…'), findsOneWidget);
    expect(
        tester.widget<FilledButton>(find.byType(FilledButton).first).onPressed,
        isNull);
    expect(find.byType(OutfitResultDialog), findsNothing);

    // The service polls every two seconds; two polls to land on 'done'.
    // Pumped by hand: the result dialog keeps a progress indicator spinning
    // while its image loads, so pumpAndSettle would never return.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 1));
    }

    expect(find.byType(OutfitResultDialog), findsOneWidget);
    expect(find.text('Generating…'), findsNothing);
    // One render, three requests for it: the POST and the two polls.
    expect(posted, hasLength(1));
    expect(jsonDecode(posted.single)['cloth_ids'], [1]);
    expect(
        requests.where((r) => r.url.path.endsWith('/outfits/42')), hasLength(2));
  });

  testWidgets('a refused render is reported, and the button comes back',
      (tester) async {
    serve(
        generateResponse: () => http.Response(
            jsonEncode({'detail': 'Daily generation limit reached'}), 429));
    await pump(tester);
    await pickFirstCloth(tester);
    await tapGenerate(tester);
    await tester.pump(const Duration(milliseconds: 400));

    expect(
        find.descendant(
            of: find.byType(SnackBar),
            matching: find.textContaining('Daily generation limit reached')),
        findsOneWidget);
    expect(find.byType(OutfitResultDialog), findsNothing);
    // Ready for another attempt: a dead button after a failure would need the
    // screen to be left and re-entered.
    expect(find.text('Generate outfit'), findsOneWidget);
    expect(
        tester.widget<FilledButton>(find.byType(FilledButton).first).onPressed,
        isNotNull);
  });
}
