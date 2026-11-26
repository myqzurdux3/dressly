import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:dressly/design/ds.dart';
import 'package:dressly/models/user.dart';
import 'package:dressly/screens/agenda/agenda_screen.dart';
import 'package:dressly/services/pinned_http.dart';
import 'package:dressly/state/providers.dart';
import 'package:dressly/state/session.dart';

/// The agenda's empty state used to say: tap "Schedule outfit" — under a button
/// labelled "Plan the week", which does something else. The sentence and the
/// button below it must name the same action, and that action must not then
/// appear a second time as a floating button.

Map<String, dynamic> _entry() => {
      'id': 1,
      'day': '2026-08-20',
      'outfit_id': null,
      'title': 'Dentist',
      'note': '',
      'worn': false,
    };

Future<void> _pump(WidgetTester tester, {required bool empty}) async {
  PinnedHttp.setClientForTesting(MockClient((_) async =>
      http.Response(jsonEncode(empty ? [] : [_entry()]), 200)));
  final session = Session()
    ..setSession(AppUser(id: 1, email: 'a@b.co', isAdmin: false), 'tok');
  await tester.pumpWidget(ProviderScope(
      overrides: [sessionProvider.overrideWith((_) => session)],
    child: MaterialApp(
      locale: const Locale('en'),
      theme: const ThemeF().themeData(Brightness.dark, DsAccent.orange),
      home: const AgendaScreen(),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  tearDown(() => PinnedHttp.setClientForTesting(null));

  testWidgets('the empty state offers exactly the action its sentence names',
      (tester) async {
    await _pump(tester, empty: true);

    // Named once, offered once: the button under the sentence IS that
    // action. The week planner stays reachable as the secondary.
    expect(find.widgetWithText(DsButton, 'Schedule outfit'), findsOneWidget);
    expect(find.widgetWithText(DsButton, 'Plan the week'), findsOneWidget);
  });

  testWidgets('with entries the schedule button stays, once', (tester) async {
    await _pump(tester, empty: false);

    expect(find.widgetWithText(DsButton, 'Schedule outfit'), findsOneWidget);
    expect(find.text('DENTIST'), findsOneWidget);
  });

  testWidgets('outfits that fail to load show an error, not "no outfits"',
      (tester) async {
    var outfitCalls = 0;
    PinnedHttp.setClientForTesting(MockClient((req) async {
      if (req.url.path.endsWith('/outfits')) {
        outfitCalls++;
        // First attempt fails, the retry succeeds.
        return outfitCalls == 1
            ? http.Response(jsonEncode({'detail': 'boom'}), 500)
            : http.Response('[]', 200);
      }
      return http.Response('[]', 200);
    }));
    final session = Session()
      ..setSession(AppUser(id: 1, email: 'a@b.co', isAdmin: false), 'tok');
    await tester.pumpWidget(ProviderScope(
      overrides: [sessionProvider.overrideWith((_) => session)],
      child: MaterialApp(
        locale: const Locale('en'),
        theme: const ThemeF().themeData(Brightness.dark, DsAccent.orange),
        home: const AgendaScreen(),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(DsButton, 'Schedule outfit'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK')); // the date picker
    // Pumped by hand: the sheet shows a spinner while it loads.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(outfitCalls, 1);
    expect(find.text('Could not load'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(outfitCalls, 2);
    expect(find.text('Could not load'), findsNothing);
  });
}
