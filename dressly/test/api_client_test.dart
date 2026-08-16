import 'dart:convert';

import 'package:dressly/config/api_config.dart';
import 'package:dressly/services/api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The network layer had no coverage at all, yet `_decode` produces every error
/// message the user is shown, and the auth header is what keeps requests from
/// silently 401-ing.

/// Captures the request and replies with a canned response.
class _Recorder {
  http.BaseRequest? last;
  final List<http.BaseRequest> all = [];
  final List<String> bodies = [];

  /// Replies the way FastAPI does: UTF-8 bytes under `application/json` with no
  /// charset parameter. Building the response from a String instead would
  /// latin-1 encode it and fail on any non-ASCII message.
  MockClient respond(int status, String body, {Map<String, String>? headers}) {
    // MockClient always hands over a materialised http.Request.
    return MockClient((req) async {
      last = req;
      all.add(req);
      bodies.add(req.body);
      return http.Response.bytes(
        utf8.encode(body),
        status,
        headers: {'content-type': 'application/json', ...?headers},
      );
    });
  }

  MockClient fail(Object error) =>
      MockClient((req) async {
        last = req;
        throw error;
      });
}

void main() {
  group('request shape', () {
    test('GET sends the bearer token and hits the configured base URL',
        () async {
      final rec = _Recorder();
      final api = ApiClient(token: 'abc123', httpClient: rec.respond(200, '[]'));

      await api.get('/clothes');

      expect(rec.last!.method, 'GET');
      expect(rec.last!.url.toString(), '$apiBaseUrl/clothes');
      expect(rec.last!.headers['Authorization'], 'Bearer abc123');
    });

    test('no Authorization header when signed out', () async {
      final rec = _Recorder();
      final api = ApiClient(token: null, httpClient: rec.respond(200, '[]'));

      await api.get('/health');

      expect(rec.last!.headers.containsKey('Authorization'), isFalse);
    });

    test('POST sends JSON with the right content type', () async {
      final rec = _Recorder();
      final api = ApiClient(token: 't', httpClient: rec.respond(200, '{}'));

      await api.post('/outfits/generate', {'cloth_ids': [1, 2]});

      final req = rec.last! as http.Request;
      expect(req.method, 'POST');
      expect(req.headers['Content-Type'], contains('application/json'));
      expect(jsonDecode(req.body), {'cloth_ids': [1, 2]});
    });

    test('PATCH and DELETE reach the right method and path', () async {
      final rec = _Recorder();
      final api = ApiClient(token: 't', httpClient: rec.respond(200, '{}'));

      await api.patch('/clothes/3/score', {'score': 5});
      expect(rec.last!.method, 'PATCH');

      await api.delete('/clothes/3');
      expect(rec.last!.method, 'DELETE');
      expect(rec.last!.url.path, '/clothes/3');
    });

    test('an absolute URL is used as-is rather than prefixed', () async {
      final rec = _Recorder();
      final api = ApiClient(token: 't', httpClient: rec.respond(200, '{}'));

      await api.get('http://other.host:9000/thing');

      expect(rec.last!.url.toString(), 'http://other.host:9000/thing');
    });
  });

  group('response decoding', () {
    test('parses a JSON object', () async {
      final rec = _Recorder();
      final api =
          ApiClient(token: 't', httpClient: rec.respond(200, '{"id":7}'));

      expect(await api.get('/clothes/7'), {'id': 7});
    });

    test('accented text survives the round trip', () async {
      // FastAPI labels JSON as `application/json` with no charset. Several
      // clothes are named in French ("short équipe de france"), so a decoder
      // that assumed latin-1 here would show mojibake throughout the wardrobe.
      final rec = _Recorder();
      final api = ApiClient(
          token: 't',
          httpClient: rec.respond(
              200, '{"name":"short équipe de france","brand":"NIKE"}'));

      final body = await api.get('/clothes/1') as Map<String, dynamic>;
      expect(body['name'], 'short équipe de france');
    });

    test('an empty body decodes to null, not a crash', () async {
      final rec = _Recorder();
      final api = ApiClient(token: 't', httpClient: rec.respond(200, ''));

      expect(await api.delete('/clothes/1'), isNull);
    });
  });

  group('error mapping', () {
    test("surfaces the backend's `detail` message", () async {
      final rec = _Recorder();
      final api = ApiClient(
          token: 't',
          httpClient: rec.respond(400, '{"detail":"Name is required"}'));

      expect(
        () => api.post('/clothes', const {}),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 400)
            .having((e) => e.message, 'message', 'Name is required')),
      );
    });

    test('falls back to a generic message when the body is not JSON', () async {
      final rec = _Recorder();
      final api =
          ApiClient(token: 't', httpClient: rec.respond(502, '<html>nope'));

      expect(
        () => api.get('/clothes'),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 502)
            .having((e) => e.message, 'message', contains('502'))),
      );
    });

    test('a 429 from the rate limiter reaches the UI with its explanation',
        () async {
      final rec = _Recorder();
      final api = ApiClient(
        token: 't',
        httpClient: rec.respond(
            429, '{"detail":"Too many requests — the limit is 30 per 60 minutes."}'),
      );

      expect(
        () => api.post('/outfits/generate', const {}),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 429)
            .having((e) => e.message, 'message', contains('Too many requests'))),
      );
    });

    test('a 401 is reported as such so the app can send the user to login',
        () async {
      final rec = _Recorder();
      final api = ApiClient(
          token: 'stale',
          httpClient: rec.respond(401, '{"detail":"Invalid or expired token"}'));

      expect(
        () => api.get('/auth/me'),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 401)),
      );
    });

    test('ApiException prints its message, since screens interpolate it', () {
      expect(ApiException(400, 'Name is required').toString(),
          'Name is required');
    });
  });

  group('multipart', () {
    test('uploads files under the `images` field with the form fields',
        () async {
      final rec = _Recorder();
      final api = ApiClient(token: 't', httpClient: rec.respond(200, '{}'));

      await api.multipartBytes(
        'POST',
        '/outfits/manual',
        fields: {'cloth_ids': '[1,2]'},
        fileField: 'image',
        bytes: [1, 2, 3, 4],
        filename: 'canvas.png',
      );

      // MockClient finalises the MultipartRequest into a plain Request, so the
      // encoded body is what there is to inspect.
      final req = rec.last!;
      expect(req.method, 'POST');
      expect(req.headers['content-type'], startsWith('multipart/form-data'));
      expect(req.headers['Authorization'], 'Bearer t');
      final body = rec.bodies.single;
      expect(body, contains('name="cloth_ids"'));
      expect(body, contains('[1,2]'));
      expect(body, contains('name="image"'));
      expect(body, contains('filename="canvas.png"'));
    });

    test('multipart errors map to ApiException like any other call', () async {
      final rec = _Recorder();
      final api = ApiClient(
          token: 't',
          httpClient: rec.respond(413, '{"detail":"Image too large"}'));

      expect(
        () => api.multipartBytes('POST', '/outfits/manual',
            fileField: 'image', bytes: const [0]),
        throwsA(isA<ApiException>()
            .having((e) => e.message, 'message', 'Image too large')),
      );
    });
  });

  group('timeouts', () {
    test('a plain read does not wait minutes', () {
      // A GET that stalls used to keep the screen spinning for the full
      // five-minute generation budget.
      for (final path in ['/clothes', '/agenda', '/outfits/favorites/list',
                          '/stats/me']) {
        expect(ApiClient.timeoutFor(path).inSeconds, lessThanOrEqualTo(30),
            reason: '$path should not inherit the generation budget');
      }
    });

    test('generation keeps its long budget', () {
      // These genuinely wait on a bfl.ai render.
      for (final path in ['/outfits/generate', '/outfits/12/regenerate',
                          '/outfits/12/replace-model', '/outfits/12/back',
                          '/clothes/1/images/2/enhance']) {
        expect(ApiClient.timeoutFor(path).inMinutes, greaterThanOrEqualTo(2),
            reason: '$path needs time to render');
      }
    });
  });

  group('transport failures', () {
    test('a GET is retried once on a transport error', () async {
      // A kept-alive socket can be dropped by the network with neither end
      // told; the request sent down it vanishes until the timeout. Reissuing
      // costs a round trip, and the user sees nothing.
      var attempts = 0;
      final api = ApiClient(
        token: 't',
        httpClient: MockClient((req) async {
          attempts++;
          if (attempts == 1) throw http.ClientException('stale socket');
          return http.Response.bytes(utf8.encode('{"ok":true}'), 200,
              headers: {'content-type': 'application/json'});
        }),
      );

      expect(await api.get('/clothes/1'), {'ok': true});
      expect(attempts, 2, reason: 'the first failure should have been retried');
    });

    test('a GET that keeps failing reports something readable', () async {
      final api = ApiClient(
        token: 't',
        httpClient: MockClient((req) async {
          throw http.ClientException('down');
        }),
      );

      // Not "ClientException: down", and certainly not
      // "TimeoutException after 0:00:20.000000: Future not completed".
      await expectLater(
        api.get('/clothes'),
        throwsA(isA<ApiException>().having((e) => e.message, 'message',
            contains('Could not reach the server'))),
      );
    });

    test('accepting a cut-out is retried', () async {
      // The reported failure: "keep the cut-out" spun for the full timeout and
      // then errored, while retrying by hand worked. Accepting twice lands in
      // the same state, so the app should do that retry itself.
      var attempts = 0;
      final api = ApiClient(
        token: 't',
        httpClient: MockClient((req) async {
          attempts++;
          if (attempts == 1) throw http.ClientException('stale socket');
          return http.Response.bytes(utf8.encode('{"ok":true}'), 200,
              headers: {'content-type': 'application/json'});
        }),
      );

      expect(await api.post('/clothes/1/images/2/accept', const {}),
          {'ok': true});
      expect(attempts, 2);
    });

    test('other state-setting writes are retried too', () async {
      for (final path in [
        '/clothes/1/images/2/reject',
        '/clothes/1/favorite',
        '/clothes/1/wear',
        '/clothes/1/images/2/redo-bg',
        '/outfits/1/blacklist',
      ]) {
        var attempts = 0;
        final api = ApiClient(
          token: 't',
          httpClient: MockClient((req) async {
            attempts++;
            if (attempts == 1) throw http.ClientException('stale socket');
            return http.Response.bytes(utf8.encode('{}'), 200,
                headers: {'content-type': 'application/json'});
          }),
        );
        await api.post(path, const {});
        expect(attempts, 2, reason: '$path should have been retried');
      }
    });

    test('a paid generation is NOT retried', () async {
      // Repeating one of these bills bfl.ai a second time.
      for (final path in [
        '/outfits/generate',
        '/clothes/1/images/2/enhance',
      ]) {
        var attempts = 0;
        final api = ApiClient(
          token: 't',
          httpClient: MockClient((req) async {
            attempts++;
            throw http.ClientException('down');
          }),
        );
        await expectLater(api.post(path, const {}), throwsA(anything));
        expect(attempts, 1, reason: '$path must not be repeated');
      }
    });

    test('a POST is NOT retried', () async {
      // Repeating a write that did reach the server would apply it twice.
      var attempts = 0;
      final api = ApiClient(
        token: 't',
        httpClient: MockClient((req) async {
          attempts++;
          throw http.ClientException('down');
        }),
      );

      await expectLater(api.post('/outfits/generate', const {}),
          throwsA(anything));
      expect(attempts, 1);
    });

    test('a server error is not mistaken for a transport failure', () async {
      // A 500 means the server answered; retrying would just repeat it.
      var attempts = 0;
      final api = ApiClient(
        token: 't',
        httpClient: MockClient((req) async {
          attempts++;
          return http.Response.bytes(
              utf8.encode('{"detail":"boom"}'), 500,
              headers: {'content-type': 'application/json'});
        }),
      );

      await expectLater(
        api.get('/clothes'),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 500)
            .having((e) => e.message, 'message', 'boom')),
      );
      expect(attempts, 1, reason: 'a 500 is an answer, not a lost connection');
    });
  });
}
