import 'dart:async';
import 'dart:io';

import 'package:clothesapp/services/pinned_http.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// Images and API calls must not share a connection pool.
///
/// HTTP/1.1 carries one request per connection at a time. With a single pool,
/// slow image downloads occupy every connection and JSON requests queue behind
/// them — so the app appeared frozen for as long as the slowest image took,
/// which for a stalled one was the whole timeout.

/// A server that answers `/fast` at once and never answers `/slow`.
Future<HttpServer> _server() async {
  final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  s.listen((req) {
    if (req.uri.path.startsWith('/slow')) return; // never respond, never close
    req.response
      ..statusCode = 200
      ..write('ok');
    req.response.close();
  });
  return s;
}

http.Client _client({required int maxConnections}) {
  final inner = HttpClient()..maxConnectionsPerHost = maxConnections;
  return IOClient(inner);
}

void main() {
  test('a stalled request blocks its OWN pool', () async {
    // Establishes that the mechanism is real before asserting the fix.
    final server = await _server();
    addTearDown(() => server.close(force: true));
    final base = 'http://127.0.0.1:${server.port}';
    final c = _client(maxConnections: 2);
    addTearDown(c.close);

    // Occupy both connections.
    unawaited(c.get(Uri.parse('$base/slow1')).catchError((_) => _dummy()));
    unawaited(c.get(Uri.parse('$base/slow2')).catchError((_) => _dummy()));
    await Future<void>.delayed(const Duration(milliseconds: 300));

    await expectLater(
      c.get(Uri.parse('$base/fast')).timeout(const Duration(seconds: 2)),
      throwsA(isA<TimeoutException>()),
      reason: 'with every connection held, a third request cannot get through',
    );
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('a stalled image does not block an API call on the other pool',
      () async {
    // The reported failure, and the reason the pools are separate.
    final server = await _server();
    addTearDown(() => server.close(force: true));
    final base = 'http://127.0.0.1:${server.port}';

    final imagePool = _client(maxConnections: 2);
    final apiPool = _client(maxConnections: 4);
    addTearDown(imagePool.close);
    addTearDown(apiPool.close);

    // Saturate the image pool with requests that never answer.
    unawaited(imagePool.get(Uri.parse('$base/slow1')).catchError((_) => _dummy()));
    unawaited(imagePool.get(Uri.parse('$base/slow2')).catchError((_) => _dummy()));
    await Future<void>.delayed(const Duration(milliseconds: 300));

    final sw = Stopwatch()..start();
    final r = await apiPool
        .get(Uri.parse('$base/fast'))
        .timeout(const Duration(seconds: 3));
    sw.stop();

    expect(r.statusCode, 200);
    expect(sw.elapsedMilliseconds, lessThan(2000),
        reason: 'the API call waited on the image pool');
  }, timeout: const Timeout(Duration(seconds: 30)));

  group('configuration', () {
    test('the API and image clients are distinct objects', () {
      expect(identical(PinnedHttp.api, PinnedHttp.images), isFalse,
          reason: 'one shared pool is what froze the app');
    });

    test('each is stable across calls, so connections are reused', () {
      expect(identical(PinnedHttp.api, PinnedHttp.api), isTrue);
      expect(identical(PinnedHttp.images, PinnedHttp.images), isTrue);
    });
  });
}

http.Response _dummy() => http.Response('', 499);
