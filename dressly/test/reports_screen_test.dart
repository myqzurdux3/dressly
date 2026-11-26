import 'dart:convert';

import 'package:dressly/design/ds.dart';
import 'package:dressly/models/report.dart';
import 'package:dressly/models/user.dart';
import 'package:dressly/screens/settings/reports_screen.dart';
import 'package:dressly/services/pinned_http.dart';
import 'package:dressly/state/providers.dart';
import 'package:dressly/state/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Fake `/notifications` router: the two lists and the resolve route.
class _Server {
  List<Map<String, Object?>> cutouts = [];
  List<Map<String, Object?>> generations = [];
  int status = 200;
  final resolved = <String>[];

  late final client = MockClient((req) async {
    final p = req.url.path;
    if (status != 200) return http.Response('{"detail":"boom"}', status);
    if (req.method == 'GET' && p.endsWith('/notifications')) {
      return http.Response(jsonEncode(cutouts), 200);
    }
    if (req.method == 'GET' && p.endsWith('/notifications/reports')) {
      return http.Response(jsonEncode(generations), 200);
    }
    if (req.method == 'POST' && p.endsWith('/resolve')) {
      resolved.add(p);
      return http.Response('{"ok":true}', 200);
    }
    return http.Response('{}', 404);
  });
}

Future<_Server> _pump(WidgetTester t, _Server s) async {
  PinnedHttp.setClientForTesting(s.client);
  addTearDown(() => PinnedHttp.setClientForTesting(null));
  await t.binding.setSurfaceSize(const Size(412, 915));
  addTearDown(() => t.binding.setSurfaceSize(null));
  final session = Session()
    ..setSession(AppUser(id: 1, email: 'a@b.co', isAdmin: true), 'tok');
  await t.pumpWidget(
    ProviderScope(
      overrides: [sessionProvider.overrideWith((_) => session)],
      child: MaterialApp(
        locale: const Locale('en'),
        theme: const ThemeF().themeData(Brightness.dark, DsAccent.orange),
        home: ReportsScreen(imageBuilder: (_) => const SizedBox.expand()),
      ),
    ),
  );
  await t.pump(); // post-frame load
  await t.pump(); // replies
  await t.pump();
  return s;
}

void main() {
  testWidgets('lists both kinds, with comment, photo and resolve action',
      (t) async {
    final s = _Server()
      ..cutouts = [
        {
          'id': 5,
          'user_id': 1,
          'reporter_email': 'a@b.co',
          'cloth_id': 9,
          'cloth_name': 'Hoodie gris',
          'image_id': 3,
          'image_role': 'front',
          'message': 'Sleeve cut off',
          'resolved': false,
          'created_at': '2026-11-20 10:00:00',
          'image_url': '/images/1/9/front.png',
        },
      ]
      ..generations = [
        {
          'id': 2,
          'user_id': 1,
          'outfit_id': 40,
          'tier': 'pro',
          'slug': '',
          'message': '',
          'resolved': 0,
          'created_at': '2026-11-21 08:30:00',
          'reporter_email': 'a@b.co',
          'outfit_status': 'done',
        },
      ];
    await _pump(t, s);

    expect(find.text('CUT-OUTS'), findsOneWidget);
    expect(find.text('GENERATIONS'), findsOneWidget);
    expect(find.text('Bad cut-out · Hoodie gris'), findsOneWidget);
    expect(find.text('Sleeve cut off'), findsOneWidget);
    expect(find.text('Bad generation · Pro · Outfit #40'), findsOneWidget);
    expect(find.text('No comment'), findsOneWidget);
    // The date is localized, not the raw SQLite text.
    expect(find.textContaining('2026-11-20'), findsNothing);
    expect(find.textContaining('Nov'), findsNWidgets(2));

    // Only the cut-out report offers the action: the server has no resolve
    // route for generation reports.
    expect(find.text('Mark as handled'), findsOneWidget);
    await t.tap(find.text('Mark as handled'));
    await t.pump();
    await t.pump();
    expect(s.resolved, ['/notifications/5/resolve']);
    expect(find.text('Mark as handled'), findsNothing);
    expect(find.text('HANDLED'), findsOneWidget);
  });

  testWidgets('no reports shows the empty state', (t) async {
    await _pump(t, _Server());
    expect(find.text('NO REPORTS'), findsOneWidget);
    expect(find.text('Mark as handled'), findsNothing);
  });

  testWidgets('a failed load offers a retry', (t) async {
    final s = _Server()..status = 500;
    await _pump(t, s);
    expect(find.textContaining('Could not load the reports'), findsOneWidget);
    s.status = 200;
    await t.tap(find.text('Retry'));
    await t.pump();
    await t.pump();
    await t.pump();
    expect(find.text('NO REPORTS'), findsOneWidget);
  });

  test('server timestamps are read as UTC', () {
    const r = UserReport(
      id: 1,
      kind: ReportKind.generation,
      message: '',
      resolved: false,
      createdAt: '2026-11-20 10:00:00',
    );
    expect(r.createdAtLocal!.toUtc(), DateTime.utc(2026, 11, 20, 10));
    expect(r.canResolve, isFalse);
  });
}
