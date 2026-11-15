import 'dart:convert';

import 'package:dressly/design/ds.dart';
import 'package:dressly/screens/wardrobe/wardrobe_card.dart';
import 'package:dressly/screens/wardrobe/wardrobe_screen.dart';
import 'package:dressly/services/api_client.dart';
import 'package:dressly/services/pinned_http.dart';
import 'package:dressly/state/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, Object?> _json(int id, String name) => {
  'id': id,
  'user_id': 1,
  'name': name,
  'brand': 'NIKE',
  'cut': 'normal',
  'category': 'hoodie',
  'custom_tags': <String>[],
  'colors': [
    {'color': 'Grey', 'dominance': 'full'},
  ],
  'images': <Object>[],
  'score': 0,
  'is_favorite': false,
};

/// Fake backend. [listQueries] records every wardrobe page query.
class _Server {
  List<Map<String, Object?>> clothes = [
    _json(1, 'Hoodie gris'),
    _json(2, 'Cargo kaki'),
    _json(3, 'Runners crème'),
  ];
  int listStatus = 200;
  int favoriteStatus = 200;
  final listQueries = <Map<String, String>>[];
  final deleted = <String>[];

  late final client = MockClient((req) async {
    final p = req.url.path;
    if (req.method == 'GET' && p.endsWith('/clothes')) {
      listQueries.add(req.url.queryParameters);
      return listStatus == 200
          ? _ok(clothes)
          : http.Response('{"detail":"boom"}', listStatus);
    }
    if (p.contains('/autocomplete/')) return _ok(<String>[]);
    if (req.method == 'POST' && p.endsWith('/favorite')) {
      return favoriteStatus == 200
          ? _ok({'is_favorite': true})
          : http.Response('{"detail":"no"}', favoriteStatus);
    }
    if (req.method == 'DELETE') {
      deleted.add(p);
      return _ok({});
    }
    return http.Response('not found', 404);
  });

  static http.Response _ok(Object body) => http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json'},
  );
}

Future<_Server> _pump(WidgetTester t, {_Server? server}) async {
  final s = server ?? _Server();
  PinnedHttp.setClientForTesting(s.client);
  addTearDown(() => PinnedHttp.setClientForTesting(null));
  await t.binding.setSurfaceSize(const Size(412, 915));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(
    ProviderScope(
      child: ProviderScope(
        // Same nesting as HomeShell: the authenticated client is scoped.
        overrides: [apiClientProvider.overrideWithValue(ApiClient(token: 't'))],
        child: MaterialApp(
          locale: const Locale('en'),
          theme: const ThemeF().themeData(Brightness.dark, DsAccent.orange),
          home: const WardrobeScreen(imageBuilder: _noImage),
        ),
      ),
    ),
  );
  await t.pump();
  await t.pump();
  return s;
}

Widget _noImage(String path, int memWidth) => const SizedBox.expand();

void main() {
  testWidgets('shows one card per garment and the count', (t) async {
    await _pump(t);
    expect(find.byType(WardrobeCard), findsNWidgets(3));
    expect(find.text('3 ITEMS'), findsOneWidget);
  });

  testWidgets('typing in search sends one request with the last text', (
    t,
  ) async {
    final s = await _pump(t);
    final before = s.listQueries.length;
    final field = find.byType(TextField);
    await t.enterText(field, 'ho');
    await t.pump(const Duration(milliseconds: 100));
    await t.enterText(field, 'hood');
    await t.pump(const Duration(milliseconds: 299));
    expect(s.listQueries.length, before);
    await t.pump(const Duration(milliseconds: 2));
    await t.pump();
    expect(s.listQueries.length, before + 1);
    expect(s.listQueries.last['search'], 'hood');
  });

  testWidgets('Favorites chip requests favorite=true', (t) async {
    final s = await _pump(t);
    await t.tap(find.text('Favorites'));
    await t.pump();
    await t.pump();
    expect(s.listQueries.last['favorite'], 'true');
  });

  testWidgets('category chip requests category=hoodie', (t) async {
    final s = await _pump(t);
    await t.ensureVisible(find.text('Hoodie'));
    await t.tap(find.text('Hoodie'));
    await t.pump();
    await t.pump();
    expect(s.listQueries.last['category'], 'hoodie');
    await t.ensureVisible(find.text('All'));
    await t.tap(find.text('All'));
    await t.pump();
    await t.pump();
    expect(s.listQueries.last.containsKey('category'), isFalse);
  });

  testWidgets('first page error shows DsError and retry reloads', (t) async {
    final s = _Server()..listStatus = 500;
    await _pump(t, server: s);
    expect(find.byType(DsError), findsOneWidget);
    // The search stays usable while the grid is in error.
    expect(find.byType(TextField), findsOneWidget);
    s.listStatus = 200;
    await t.tap(find.text('Retry'));
    await t.pump();
    await t.pump();
    expect(find.byType(WardrobeCard), findsNWidgets(3));
  });

  testWidgets('empty wardrobe shows DsEmpty', (t) async {
    await _pump(t, server: _Server()..clothes = []);
    expect(find.byType(DsEmpty), findsOneWidget);
  });

  testWidgets('favourite failure shows a snackbar and keeps the card', (
    t,
  ) async {
    await _pump(t, server: _Server()..favoriteStatus = 500);
    await t.tap(find.bySemanticsLabel('Favorite clothes').first);
    await t.pump();
    await t.pump();
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.byIcon(Icons.favorite), findsNothing);
  });

  testWidgets('long press then confirm deletes and removes the card', (
    t,
  ) async {
    final s = await _pump(t);
    await t.longPress(find.text('Hoodie gris'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.text('Delete'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(s.deleted, ['/clothes/1']);
    expect(find.byType(WardrobeCard), findsNWidgets(2));
  });
}
