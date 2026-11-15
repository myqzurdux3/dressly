import 'dart:convert';

import 'package:dressly/design/ds.dart';
import 'package:dressly/screens/cloth/cloth_detail_screen.dart';
import 'package:dressly/services/api_client.dart';
import 'package:dressly/services/pinned_http.dart';
import 'package:dressly/state/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, Object?> _image({
  int id = 11,
  String role = 'front',
  String bg = 'accepted',
  String? enhance,
  String? nextTier,
  String? pendingMethod,
}) => {
  'id': id,
  'role': role,
  'sort_order': 0,
  'bg_accepted': bg,
  'bg_tolerance': 'medium',
  'original_url': '/o/$id.jpg',
  'cutout_url': '/c/$id.png',
  'preview_url': '/p/$id.jpg',
  'enhance_status': enhance,
  'enhance_next_tier': nextTier,
  'enhance_pending_method': pendingMethod,
  'enhance_error': enhance == 'failed' ? 'model refused' : null,
};

/// Fake backend for garment 5.
class _Server {
  Map<String, Object?> cloth = {
    'id': 5,
    'user_id': 1,
    'name': 'Hoodie gris',
    'brand': 'NIKE',
    'cut': 'oversize',
    'category': 'hoodie',
    'custom_tags': ['hiver'],
    'colors': [
      {'color': 'Grey', 'dominance': 'full'},
    ],
    'images': [_image()],
    'score': 3,
    'is_favorite': false,
  };
  int getStatus = 200;
  final calls = <String>[];
  final bodies = <String, Object?>{};

  late final client = MockClient((req) async {
    final p = req.url.path;
    if (req.method != 'GET') {
      calls.add('${req.method} $p');
      if (req.body.isNotEmpty) bodies[p] = jsonDecode(req.body);
    }
    if (req.method == 'GET' && p.endsWith('/clothes/5')) {
      return getStatus == 200
          ? _ok(cloth)
          : http.Response('{"detail":"boom"}', getStatus);
    }
    if (p.endsWith('/favorite')) {
      cloth = {...cloth, 'is_favorite': true};
      return _ok({'is_favorite': true});
    }
    if (p.endsWith('/redo-bg')) return _ok(cloth);
    if (p.endsWith('/enhance-describe')) return _ok(cloth);
    return _ok({});
  });

  static http.Response _ok(Object body) => http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json'},
  );
}

Widget _noImage(String url, String key, int w) => const SizedBox.expand();

Future<_Server> _pump(WidgetTester t, [_Server? server]) async {
  final s = server ?? _Server();
  PinnedHttp.setClientForTesting(s.client);
  addTearDown(() => PinnedHttp.setClientForTesting(null));
  await t.binding.setSurfaceSize(const Size(412, 915));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(
    ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(ApiClient(token: 't'))],
      child: MaterialApp(
        locale: const Locale('en'),
        theme: const ThemeF().themeData(Brightness.dark, DsAccent.orange),
        home: const ClothDetailScreen(clothId: 5, imageBuilder: _noImage),
      ),
    ),
  );
  await t.pump();
  await t.pump();
  return s;
}

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 5; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('shows the garment: name, brand, facts, rating', (t) async {
    await _pump(t);
    expect(find.text('HOODIE GRIS'), findsOneWidget);
    expect(find.text('NIKE'), findsOneWidget);
    expect(find.text('#hiver'), findsOneWidget);
    expect(find.byType(DsRating), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
  });

  testWidgets('first load error shows DsError, retry loads', (t) async {
    final s = await _pump(t, _Server()..getStatus = 500);
    expect(find.byType(DsError), findsOneWidget);
    s.getStatus = 200;
    await t.tap(find.text('Retry'));
    await _settle(t);
    expect(find.text('HOODIE GRIS'), findsOneWidget);
  });

  testWidgets('favourite posts, then shows the filled heart', (t) async {
    final s = await _pump(t);
    await t.tap(find.bySemanticsLabel('Favorite'));
    await _settle(t);
    expect(s.calls, ['POST /clothes/5/favorite']);
    expect(find.byIcon(Icons.favorite), findsOneWidget);
  });

  testWidgets('a failed refresh keeps the garment on screen', (t) async {
    final s = await _pump(t);
    s.getStatus = 500;
    await t.tap(find.bySemanticsLabel('Favorite'));
    await _settle(t);
    expect(find.text('HOODIE GRIS'), findsOneWidget);
    expect(find.byType(DsError), findsNothing);
  });

  testWidgets('rating tap sends the score', (t) async {
    final s = await _pump(t);
    await t.tap(find.bySemanticsLabel('5 / 5'));
    await _settle(t);
    expect(s.bodies['/clothes/5/score'], {'score': 5});
  });

  testWidgets('cut-out strength sends the tolerance once', (t) async {
    final s = await _pump(t);
    await t.ensureVisible(find.text('Strong'));
    await t.pump();
    await t.tap(find.text('Strong'));
    await t.tap(find.text('Strong'));
    await _settle(t);
    expect(s.calls.where((c) => c.endsWith('redo-bg')).length, 1);
    expect(s.bodies['/clothes/5/images/11/redo-bg'], {'tolerance': 'high'});
  });

  testWidgets('a pending photo offers the cut-out choice', (t) async {
    final s = _Server();
    s.cloth = {
      ...s.cloth,
      'images': [_image(bg: 'pending')],
    };
    await _pump(t, s);
    expect(find.byIcon(Icons.compare), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsNothing);
  });

  testWidgets('a failed enhancement offers retry and a stronger model', (
    t,
  ) async {
    final s = _Server();
    s.cloth = {
      ...s.cloth,
      'images': [
        _image(enhance: 'failed', nextTier: 'pro', pendingMethod: 'ai'),
      ],
    };
    await _pump(t, s);
    await t.ensureVisible(find.text('model refused'));
    await t.pump();
    expect(find.byIcon(Icons.refresh), findsOneWidget);
    expect(find.byIcon(Icons.upgrade), findsOneWidget);
  });

  testWidgets('describe toggle shows at once and saves', (t) async {
    final s = await _pump(t);
    await t.ensureVisible(find.byType(Checkbox));
    await t.pump();
    expect(t.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
    await t.tap(find.byType(Checkbox));
    await t.pump();
    expect(t.widget<Checkbox>(find.byType(Checkbox)).value, isFalse);
    await _settle(t);
    expect(s.bodies['/clothes/5/images/11/enhance-describe'], {
      'describe': false,
    });
  });

  testWidgets('delete confirms, deletes and pops', (t) async {
    final s = await _pump(t);
    await t.tap(find.bySemanticsLabel('Delete'));
    await _settle(t);
    await t.tap(find.widgetWithText(FilledButton, 'Delete'));
    await _settle(t);
    expect(s.calls, ['DELETE /clothes/5']);
  });
}
