import 'dart:io';

import 'package:clothesapp/services/pinned_http.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// Certificate pinning is the only thing that makes a self-signed server safe:
/// if the app accepted any certificate, the connection would look encrypted
/// while anyone in the middle could read it.
///
/// Dart only ever hands out an X509Certificate from a live connection, so these
/// start real TLS servers with the certificates produced by
/// `backend/scripts/make_cert.py` and connect to them.

/// A self-signed server, plus the fingerprint of the certificate it presents.
class _TlsServer {
  _TlsServer(this.server, this.fingerprint);

  final HttpServer server;
  final String fingerprint;

  int get port => server.port;

  static Future<_TlsServer> start(Directory certDir) async {
    final crt = File('${certDir.path}/server.crt');
    final key = File('${certDir.path}/server.key');
    final ctx = SecurityContext()
      ..useCertificateChain(crt.path)
      ..usePrivateKey(key.path);
    final server =
        await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, ctx);
    server.listen((req) {
      req.response
        ..statusCode = 200
        ..write('ok');
      req.response.close();
    });
    return _TlsServer(server, _fingerprintOfPem(crt.readAsBytesSync()));
  }

  Future<void> stop() => server.close(force: true);
}

/// SHA-256 over the DER inside a PEM file — the value make_cert.py prints.
String _fingerprintOfPem(List<int> pemBytes) {
  final pem = String.fromCharCodes(pemBytes);
  final body = pem
      .split('\n')
      .where((l) => !l.startsWith('-----') && l.trim().isNotEmpty)
      .join();
  return sha256.convert(_base64(body)).toString();
}

List<int> _base64(String s) {
  const table =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  final out = <int>[];
  var buffer = 0, bits = 0;
  for (final ch in s.split('')) {
    if (ch == '=') break;
    final v = table.indexOf(ch);
    if (v < 0) continue;
    buffer = (buffer << 6) | v;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out.add((buffer >> bits) & 0xFF);
    }
  }
  return out;
}

/// Generates a throwaway certificate with the project's own script.
Future<Directory?> _makeCert(String name) async {
  final dir = Directory.systemTemp.createTempSync('pin_$name');
  final script = File('../backend/scripts/make_cert.py');
  if (!script.existsSync()) return null;
  final res = await Process.run(
    'python3',
    [script.absolute.path, '--host', '127.0.0.1', '--force'],
    environment: {'PYTHONPATH': '../backend'},
    workingDirectory: '../backend',
  );
  if (res.exitCode != 0) return null;
  for (final f in ['server.crt', 'server.key']) {
    File('../backend/certs/$f').copySync('${dir.path}/$f');
  }
  return dir;
}

Future<String> _get(HttpClient client, int port) async {
  final req = await client.getUrl(Uri.parse('https://127.0.0.1:$port/'));
  final resp = await req.close();
  return resp.transform(const SystemEncoding().decoder).join();
}

void main() {
  tearDown(() => PinnedHttp.setPinForTesting(''));

  group('against a real TLS server', () {
    late Directory certA;
    late Directory certB;

    setUpAll(() async {
      final a = await _makeCert('a');
      final b = await _makeCert('b');
      if (a == null || b == null) {
        markTestSkipped('make_cert.py unavailable');
        return;
      }
      certA = a;
      certB = b;
    });

    test('the pinned certificate is accepted', () async {
      final server = await _TlsServer.start(certA);
      addTearDown(server.stop);
      PinnedHttp.setPinForTesting(server.fingerprint);

      final client = HttpClient()
        ..badCertificateCallback = (c, h, p) => PinnedHttp.accepts(c);

      expect(await _get(client, server.port), 'ok');
    }, skip: !Directory('../backend/scripts').existsSync());

    test('a DIFFERENT certificate is refused', () async {
      // The MITM case: an attacker terminates TLS with their own certificate.
      final server = await _TlsServer.start(certB);
      addTearDown(server.stop);
      PinnedHttp.setPinForTesting(
          _fingerprintOfPem(File('${certA.path}/server.crt').readAsBytesSync()));

      final client = HttpClient()
        ..badCertificateCallback = (c, h, p) => PinnedHttp.accepts(c);

      await expectLater(_get(client, server.port), throwsA(isA<HandshakeException>()));
    }, skip: !Directory('../backend/scripts').existsSync());

    test('with no pin configured, a self-signed server is refused', () async {
      final server = await _TlsServer.start(certA);
      addTearDown(server.stop);
      PinnedHttp.setPinForTesting('');

      final client = HttpClient()
        ..badCertificateCallback = (c, h, p) => PinnedHttp.accepts(c);

      await expectLater(_get(client, server.port), throwsA(isA<HandshakeException>()));
    }, skip: !Directory('../backend/scripts').existsSync());

    test('the fingerprint matches what make_cert.py reported', () async {
      final server = await _TlsServer.start(certA);
      addTearDown(server.stop);
      String? seen;
      final client = HttpClient()
        ..badCertificateCallback = (c, h, p) {
          seen = PinnedHttp.fingerprintOf(c);
          return true;
        };
      await _get(client, server.port);

      expect(seen, server.fingerprint);
      expect(seen!.length, 64);
    }, skip: !Directory('../backend/scripts').existsSync());
  });

  group('pin parsing', () {
    test('colons and upper case are accepted, as printed by make_cert.py', () {
      const hex =
          'e7db9917ed4540fc5fa7cfeb19fbd79b290ee5e228452155d5972ef9f1626530';
      final pretty = [
        for (var i = 0; i < hex.length; i += 2) hex.substring(i, i + 2)
      ].join(':').toUpperCase();

      PinnedHttp.setPinForTesting(pretty);
      expect(PinnedHttp.isPinned, isTrue);
      PinnedHttp.setPinForTesting(hex);
      expect(PinnedHttp.isPinned, isTrue);
    });

    test('an empty pin means "not pinned"', () {
      PinnedHttp.setPinForTesting('');
      expect(PinnedHttp.isPinned, isFalse);
    });
  });
}
