import 'package:dressly/models/user.dart';
import 'package:dressly/services/pinned_http.dart';
import 'package:dressly/state/providers.dart';
import 'package:dressly/state/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets('services follow the session token, routes included', (t) async {
    final auth = <String?>[];
    PinnedHttp.setClientForTesting(
      MockClient((req) async {
        auth.add(req.headers['Authorization']);
        return http.Response(
          '[]',
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(() => PinnedHttp.setClientForTesting(null));
    final session = Session()
      ..setSession(AppUser(id: 1, email: 'a@b.co', isAdmin: false), 'a');
    late WidgetRef ref;
    await t.pumpWidget(
      ProviderScope(
        overrides: [sessionProvider.overrideWith((_) => session)],
        child: MaterialApp(
          home: Consumer(
            builder: (c, r, _) {
              ref = r;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    await ref.read(clothesServiceProvider).list(limit: 1);
    final first = ref.read(apiClientProvider);
    session.setSession(AppUser(id: 1, email: 'x@b.co', isAdmin: false), 'a');
    await t.pump();
    // Same token, session notified: the very same client (no refetch cascade).
    expect(ref.read(apiClientProvider), same(first));
    session.setSession(AppUser(id: 2, email: 'b@b.co', isAdmin: false), 'b');
    await t.pump();
    await ref.read(clothesServiceProvider).list(limit: 1);
    expect(auth, ['Bearer a', 'Bearer b']);
  });
}
