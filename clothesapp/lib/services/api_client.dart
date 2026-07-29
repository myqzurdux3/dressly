import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import 'pinned_http.dart';

/// Thin wrapper around package:http that injects the bearer token, handles
/// JSON encode/decode, and turns non-2xx responses into typed exceptions.
class ApiClient {
  /// [httpClient] exists so tests can substitute `MockClient`. Production code
  /// leaves it null and gets a fresh client per request, exactly as the
  /// top-level `http.get`/`http.post` helpers did before.
  ApiClient({required this.token, http.Client? httpClient})
      : _client = httpClient ?? _shared;

  /// The API's own connection pool, separate from image downloads so a slow
  /// image cannot delay a JSON request.
  static http.Client get _shared => PinnedHttp.api;

  String? token;

  final http.Client _client;

  /// All requests share a generous timeout. Regenerating an outfit (POST
  /// /outfits/{id}/regenerate) can take 25-60s end-to-end (bfl poll + image
  /// download), so the default would be too tight. The timeout surfaces as
  /// a clear "Request timed out" exception instead of an indefinite hang.
  static const Duration _timeout = Duration(minutes: 5);

  /// Deadline for ordinary reads and writes.
  ///
  /// The five-minute budget above exists for image generation, but it was
  /// applied to everything — so a stalled connection on a plain `GET /agenda`
  /// left the screen spinning for five minutes while the server's log showed
  /// the request it did receive completing normally. A list request that has
  /// not answered in twenty seconds is not going to.
  static const Duration _readTimeout = Duration(seconds: 20);

  /// Endpoints that legitimately take minutes: they wait on a bfl.ai render.
  static bool _isSlowPath(String path) =>
      path.contains('/generate') ||
      path.contains('/regenerate') ||
      path.contains('/replace-') ||
      path.contains('/enhance') ||
      path.endsWith('/back');

  /// Visible for tests: which budget a path gets.
  static Duration timeoutFor(String path) =>
      _isSlowPath(path) ? _timeout : _readTimeout;

  Map<String, String> _headers({bool json = true}) {
    return {
      if (json) 'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  /// Run [send] against a client, disposing a per-request one when the caller
  /// did not inject their own.
  /// Errors that mean "the connection went nowhere", as opposed to the server
  /// having answered something. Only these are worth retrying.
  static bool _isTransport(Object e) =>
      e is TimeoutException ||
      e is SocketException ||
      e is http.ClientException ||
      e is HandshakeException;

  Future<dynamic> _send(String path,
      Future<http.Response> Function(http.Client) send,
      {bool retry = false}) async {
    try {
      return _decode(await send(_client).timeout(timeoutFor(path)));
    } catch (e) {
      if (!retry || !_isTransport(e)) throw _friendly(e);
      // One retry, on a fresh connection. A kept-alive socket can be dropped by
      // the network without either end being told, and the request sent down it
      // then vanishes until the timeout. Reissuing takes a round trip; not
      // reissuing shows the user a failure for something that works.
      try {
        return _decode(await send(_client).timeout(timeoutFor(path)));
      } catch (e) {
        throw _friendly(e);
      }
    }
  }

  /// Turn a transport failure into something worth showing.
  ///
  /// Dart's own message for a timeout is "TimeoutException after
  /// 0:00:20.000000: Future not completed", which tells the user nothing about
  /// what happened or what to do. Anything else is passed through untouched —
  /// an ApiException already carries the server's own wording.
  static Object _friendly(Object e) {
    if (e is ApiException) return e;
    if (e is TimeoutException) {
      return ApiException(0, 'The server did not answer in time. '
          'Check your connection and try again.');
    }
    if (e is SocketException || e is HandshakeException ||
        e is http.ClientException) {
      return ApiException(0, 'Could not reach the server. '
          'Check your connection and try again.');
    }
    return e;
  }

  Future<dynamic> get(String path) => _send(path, (c) =>
      c.get(Uri.parse(apiUrl(path)), headers: _headers(json: false)),
      // Safe to repeat: a GET changes nothing. POST and PATCH are not retried,
      // since a request that did reach the server would be applied twice.
      retry: true);

  Future<dynamic> post(String path, Map<String, dynamic> body) =>
      _send(path, (c) => c.post(Uri.parse(apiUrl(path)),
          headers: _headers(), body: jsonEncode(body)));

  Future<dynamic> delete(String path) => _send(path, (c) =>
      c.delete(Uri.parse(apiUrl(path)), headers: _headers(json: false)));

  Future<dynamic> patch(String path, Map<String, dynamic> body) =>
      _send(path, (c) => c.patch(Uri.parse(apiUrl(path)),
          headers: _headers(), body: jsonEncode(body)));

  /// Multipart upload. File list is mapped to the `images` field; the first
  /// two are sent in order (front, back) per the backend contract.
  Future<dynamic> postMultipart(
    String path, {
    required Map<String, String> fields,
    required List<File> files,
  }) async {
    final req = http.MultipartRequest('POST', Uri.parse(apiUrl(path)));
    req.headers.addAll(_headers(json: false));
    req.fields.addAll(fields);
    for (final f in files) {
      req.files.add(await http.MultipartFile.fromPath('images', f.path));
    }
    return _sendMultipart(req);
  }

  /// Multipart PUT — used by the edit-cloth form. Mirrors [postMultipart]
  /// but sends a PUT so the route matches the backend `PUT /clothes/{id}`.
  Future<dynamic> putMultipart(
    String path, {
    required Map<String, String> fields,
    required List<File> files,
  }) async {
    final req = http.MultipartRequest('PUT', Uri.parse(apiUrl(path)));
    req.headers.addAll(_headers(json: false));
    req.fields.addAll(fields);
    for (final f in files) {
      req.files.add(await http.MultipartFile.fromPath('images', f.path));
    }
    return _sendMultipart(req);
  }

  /// Generic multipart request (POST or PUT) with named file fields — used by
  /// the per-image add/replace endpoints (`image` field), unlike the
  /// front/back upload helpers above which repeat an `images` field.
  Future<dynamic> multipart(
    String method,
    String path, {
    Map<String, String> fields = const {},
    Map<String, File> files = const {},
  }) async {
    final req = http.MultipartRequest(method, Uri.parse(apiUrl(path)));
    req.headers.addAll(_headers(json: false));
    req.fields.addAll(fields);
    for (final e in files.entries) {
      req.files.add(await http.MultipartFile.fromPath(e.key, e.value.path));
    }
    return _sendMultipart(req);
  }

  /// Multipart request whose single file comes from in-memory bytes (not a
  /// path) — used to upload the manual outfit builder's rasterised canvas.
  Future<dynamic> multipartBytes(
    String method,
    String path, {
    Map<String, String> fields = const {},
    required String fileField,
    required List<int> bytes,
    String filename = 'upload.png',
  }) async {
    final req = http.MultipartRequest(method, Uri.parse(apiUrl(path)));
    req.headers.addAll(_headers(json: false));
    req.fields.addAll(fields);
    req.files.add(http.MultipartFile.fromBytes(fileField, bytes,
        filename: filename));
    return _sendMultipart(req);
  }

  /// Multipart requests bypass [_send] because they stream rather than return a
  /// Response directly, but must use the same injected client and timeout.
  Future<dynamic> _sendMultipart(http.MultipartRequest req) async {
    // Uploads carry photos and may trigger a render: keep the long budget.
    final streamed = await _client.send(req).timeout(_timeout);
    return _decode(await http.Response.fromStream(streamed));
  }

  dynamic _decode(http.Response resp) {
    if (resp.statusCode >= 400) {
      String detail = 'Request failed (${resp.statusCode})';
      try {
        final body = jsonDecode(resp.body);
        if (body is Map && body['detail'] != null) {
          detail = body['detail'].toString();
        }
      } catch (_) {}
      throw ApiException(resp.statusCode, detail);
    }
    if (resp.body.isEmpty) return null;
    return jsonDecode(resp.body);
  }
}

class ApiException implements Exception {
  ApiException(this.statusCode, this.message);
  final int statusCode;
  final String message;

  @override
  String toString() => message;
}