import 'dart:async';
import 'dart:io';

import 'package:clothesapp/services/timeout_file_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// A request that never answers must fail rather than hang.
///
/// flutter_cache_manager allows ten concurrent downloads and releases a slot in
/// a `finally` — which a request that never completes never reaches. One such
/// request costs a slot permanently; ten and the app stops loading images for
/// good, while the server's log shows everything it received completing fine.

/// Accepts connections and then says nothing, forever.
Future<ServerSocket> _blackHole() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  s.listen((socket) {/* never respond, never close */});
  return s;
}

void main() {
  test('a request that never answers times out', () async {
    final server = await _blackHole();
    addTearDown(() => server.close());

    final svc = TimeoutFileService(
      httpClient: http.Client(),
      timeout: const Duration(milliseconds: 600),
    );

    final sw = Stopwatch()..start();
    await expectLater(
      svc.get('http://127.0.0.1:${server.port}/never'),
      throwsA(isA<TimeoutException>()),
    );
    sw.stop();

    expect(sw.elapsedMilliseconds, lessThan(5000),
        reason: 'it hung instead of timing out');
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('ten stalled requests do not block the eleventh', () async {
    // The failure mode in full: without a deadline these would hold every
    // download slot and nothing further would ever load.
    final server = await _blackHole();
    addTearDown(() => server.close());

    final svc = TimeoutFileService(
      httpClient: http.Client(),
      timeout: const Duration(milliseconds: 400),
    );

    final stalled = List.generate(
        10,
        (i) => svc
            .get('http://127.0.0.1:${server.port}/stall$i')
            .then<String>((_) => 'ok', onError: (_) => 'failed'));

    final results = await Future.wait(stalled)
        .timeout(const Duration(seconds: 10));

    expect(results.every((r) => r == 'failed'), isTrue);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('a healthy response is untouched', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) {
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType('image', 'webp')
        ..add([0x52, 0x49, 0x46, 0x46]);
      req.response.close();
    });

    final svc = TimeoutFileService(httpClient: http.Client());
    final resp = await svc.get('http://127.0.0.1:${server.port}/ok');

    expect(resp.statusCode, 200);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('a transient failure is retried once', () async {
    // Same reasoning as the API: a socket the network killed silently should
    // cost a round trip, not a missing picture.
    //
    // A raw socket server, not HttpServer: the failure has to happen BEFORE any
    // response headers, otherwise the request has already succeeded as far as
    // the client is concerned and there is nothing to retry.
    var connections = 0;
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close());
    server.listen((socket) {
      connections++;
      if (connections == 1) {
        socket.destroy();          // dropped before answering
        return;
      }
      socket.listen((_) {
        socket.write('HTTP/1.1 200 OK\r\n'
            'Content-Type: image/webp\r\n'
            'Content-Length: 4\r\n'
            'Connection: close\r\n\r\nRIFF');
        socket.close();
      });
    });

    final svc = TimeoutFileService(httpClient: http.Client());
    final resp = await svc.get('http://127.0.0.1:${server.port}/flaky');

    expect(resp.statusCode, 200);
    expect(connections, 2, reason: 'the dropped connection was not retried');
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('the default deadline is generous but finite', () {
    final svc = TimeoutFileService(httpClient: http.Client());
    expect(svc.timeout.inSeconds, greaterThanOrEqualTo(10));
    expect(svc.timeout.inSeconds, lessThanOrEqualTo(60));
  });
}
