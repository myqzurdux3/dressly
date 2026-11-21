import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:dressly/design/ds.dart';
import 'package:dressly/models/user.dart';
import 'package:dressly/screens/stylist/stylist_screen.dart';
import 'package:dressly/services/pinned_http.dart';
import 'package:dressly/state/session.dart';

/// The stylist: a suggestion sends a question, the reply and its outfit card
/// come back from the polled thread, and the card saves with one tap.

Map<String, dynamic> _thread({required bool saved}) => {
  'id': 7,
  'title': 'What should I wear today?',
  'pending': false,
  'error': '',
  'messages': [
    {'id': 1, 'role': 'user', 'text': 'What should I wear today?'},
    {
      'id': 2,
      'role': 'assistant',
      'text': 'It is **cold**:\n- a hoodie\n- the grey jogging',
      'proposals': [
        {
          'id': 3,
          'title': 'Cold Saturday',
          'reason': 'Warm and simple.',
          'cloth_ids': [1, 2],
          'cloths': [
            {'id': 1, 'name': 'hoodie', 'category': 'hoodie', 'thumb_url': ''},
            {
              'id': 2,
              'name': 'jogging',
              'category': 'jogging',
              'thumb_url': '',
            },
          ],
          'outfit_id': saved ? 40 : null,
        },
      ],
    },
  ],
};

Future<List<String>> _pump(WidgetTester tester, {bool available = true}) async {
  final calls = <String>[];
  PinnedHttp.setClientForTesting(
    MockClient((req) async {
      final path = req.url.path;
      calls.add('${req.method} $path');
      if (path.endsWith('/stylist/status')) {
        return http.Response(jsonEncode({'available': available}), 200);
      }
      if (path.endsWith('/stylist/chat')) {
        return http.Response(
          jsonEncode({'thread_id': 7, 'pending': true}),
          200,
        );
      }
      if (path.endsWith('/stylist/threads/7')) {
        return http.Response(jsonEncode(_thread(saved: false)), 200);
      }
      if (path.endsWith('/stylist/proposals/3/save')) {
        return http.Response(
          jsonEncode({'outfit_id': 40, 'created': true}),
          200,
        );
      }
      return http.Response('{}', 404);
    }),
  );
  final session = Session()
    ..setSession(AppUser(id: 1, email: 'a@b.co', isAdmin: false), 'tok');
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: session,
      child: MaterialApp(
        locale: const Locale('en'),
        theme: const ThemeF().themeData(Brightness.dark, DsAccent.orange),
        home: const StylistScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return calls;
}

void main() {
  tearDown(() => PinnedHttp.setClientForTesting(null));

  testWidgets('without a key the screen says so', (tester) async {
    await _pump(tester, available: false);
    expect(find.text('THE STYLIST IS NOT SET UP'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('a suggestion gets a reply with an outfit card that saves', (
    tester,
  ) async {
    final calls = await _pump(tester);
    await tester.tap(find.text('What should I wear today?'));
    await tester.pump();
    expect(find.text('Looking through your wardrobe…'), findsOneWidget);
    // The service polls every second.
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    expect(find.text('COLD SATURDAY'), findsOneWidget);
    expect(find.textContaining('grey jogging'), findsOneWidget);
    expect(calls, contains('POST /stylist/chat'));

    await tester.tap(find.text('Add to my outfits'));
    await tester.pumpAndSettle();
    expect(calls, contains('POST /stylist/proposals/3/save'));
    expect(find.text('Open the outfit'), findsOneWidget);
  });
}
