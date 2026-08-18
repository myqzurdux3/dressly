import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

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
    child: const MaterialApp(locale: Locale('en'), home: AgendaScreen()),
  ));
  await tester.pumpAndSettle();
}

void main() {
  tearDown(() => PinnedHttp.setClientForTesting(null));

  testWidgets('the empty state offers exactly the action its sentence names',
      (tester) async {
    await _pump(tester, empty: true);

    expect(find.textContaining('Schedule outfit'), findsWidgets);
    // Named once, offered once: the button under the sentence IS that action,
    // and the floating button is gone rather than repeating it.
    expect(find.widgetWithText(FilledButton, 'Schedule outfit'), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsNothing);
    // The week planner stays reachable, as the secondary it is.
    expect(find.widgetWithText(TextButton, 'Plan the week'), findsOneWidget);
  });

  testWidgets('with entries the floating button is back', (tester) async {
    await _pump(tester, empty: false);

    expect(find.byType(FloatingActionButton), findsOneWidget);
    expect(find.text('Dentist'), findsOneWidget);
  });
}
