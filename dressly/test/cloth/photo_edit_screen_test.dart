import 'dart:convert';

import 'package:dressly/design/ds.dart';
import 'package:dressly/models/cloth.dart';
import 'package:dressly/screens/cloth/photo_edit_screen.dart';
import 'package:dressly/services/api_client.dart';
import 'package:dressly/services/pinned_http.dart';
import 'package:dressly/state/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final _clothJson = {
  'id': 5,
  'user_id': 1,
  'name': 'Hoodie',
  'brand': '',
  'cut': 'normal',
  'category': 'hoodie',
  'custom_tags': <String>[],
  'colors': <Object>[],
  'images': [
    {
      'id': 11,
      'role': 'front',
      'bg_accepted': 'accepted',
      'bg_tolerance': 'high',
      'original_url': '/o.jpg',
      'cutout_url': '/c.png',
    },
  ],
  'score': 0,
};

ClothImage get _image => ClothImage(
  id: 11,
  role: 'front',
  sortOrder: 0,
  bgAccepted: 'accepted',
  originalUrl: '/o.jpg',
  cutoutUrl: '/c.png',
);

void main() {
  late List<String> calls;
  late Map<String, Object?> bodies;
  Object? popped = 'not popped';

  Future<void> pump(WidgetTester t) async {
    calls = [];
    bodies = {};
    popped = 'not popped';
    PinnedHttp.setClientForTesting(
      MockClient((req) async {
        calls.add('${req.method} ${req.url.path}');
        if (req.body.isNotEmpty) bodies[req.url.path] = jsonDecode(req.body);
        return http.Response(
          jsonEncode(_clothJson),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(() => PinnedHttp.setClientForTesting(null));
    await t.binding.setSurfaceSize(const Size(412, 915));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(
      ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(ApiClient(token: 't'))],
        child: MaterialApp(
          locale: const Locale('en'),
          theme: const ThemeF().themeData(Brightness.dark, DsAccent.orange),
          home: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () async {
                  popped = await Navigator.push<Cloth>(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          PhotoEditScreen(clothId: 5, image: _image),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('open'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
  }

  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('done without changes sends nothing and pops null', (t) async {
    await pump(t);
    await t.tap(find.text('Done'));
    await settle(t);
    expect(calls, isEmpty);
    expect(popped, isNull);
  });

  testWidgets('rotate then done applies the rotation and returns the cloth', (
    t,
  ) async {
    await pump(t);
    await t.tap(find.bySemanticsLabel('Rotate right'));
    await t.pump();
    await t.tap(find.text('Done'));
    await settle(t);
    expect(calls, ['POST /clothes/5/images/11/transform']);
    expect((bodies['/clothes/5/images/11/transform'] as Map)['rotate'], 90);
    expect(popped, isA<Cloth>());
  });

  testWidgets('a strength re-runs the cut-out and stays open', (t) async {
    await pump(t);
    await t.tap(find.text('Strong'));
    await settle(t);
    expect(calls, ['POST /clothes/5/images/11/redo-bg']);
    expect(bodies['/clothes/5/images/11/redo-bg'], {'tolerance': 'high'});
    expect(find.byType(PhotoEditScreen), findsOneWidget);
  });
}
