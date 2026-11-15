import 'package:dressly/services/api_client.dart';
import 'package:dressly/services/pinned_http.dart';
import 'package:dressly/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final auth = <String?>[];
  setUp(() {
    auth.clear();
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
  });
  tearDown(() => PinnedHttp.setClientForTesting(null));

  test('clothesServiceProvider uses the overridden api client', () async {
    final c = ProviderContainer(
      overrides: [apiClientProvider.overrideWithValue(ApiClient(token: 't1'))],
    );
    addTearDown(c.dispose);
    await c.read(clothesServiceProvider).list(limit: 1);
    expect(auth, ['Bearer t1']);
  });

  test('reading apiClientProvider without override throws', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(() => c.read(apiClientProvider), throwsA(anything));
  });
}
