import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:dressly/design/ds.dart';
import 'package:dressly/models/user.dart';
import 'package:dressly/screens/agenda/agenda_screen.dart';
import 'package:dressly/services/pinned_http.dart';
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
  await tester.pumpWidget(ChangeNotifierProvider.value(
    value: session,
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
}
