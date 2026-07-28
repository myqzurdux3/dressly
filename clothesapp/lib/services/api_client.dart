import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../config/api_config.dart';

/// Thin wrapper around package:http that injects the bearer token, handles
/// JSON encode/decode, and turns non-2xx responses into typed exceptions.
class ApiClient {
  /// [httpClient] exists so tests can substitute `MockClient`. Production code
  /// leaves it null and gets a fresh client per request, exactly as the
  /// top-level `http.get`/`http.post` helpers did before.
  ApiClient({required this.token, http.Client? httpClient})
      : _client = httpClient;

  String? token;

  final http.Client? _client;

  /// All requests share a generous timeout. Regenerating an outfit (POST
  /// /outfits/{id}/regenerate) can take 25-60s end-to-end (bfl poll + image
  /// download), so the default would be too tight. The timeout surfaces as
  /// a clear "Request timed out" exception instead of an indefinite hang.
  static const Duration _timeout = Duration(minutes: 5);

  Map<String, String> _headers({bool json = true}) {
    return {
      if (json) 'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  /// Run [send] against a client, disposing a per-request one when the caller
  /// did not inject their own.
  Future<dynamic> _send(Future<http.Response> Function(http.Client) send) async {
    final client = _client ?? http.Client();
    try {
      return _decode(await send(client).timeout(_timeout));
    } finally {
      if (_client == null) client.close();
    }
  }

  Future<dynamic> get(String path) => _send((c) =>
      c.get(Uri.parse(apiUrl(path)), headers: _headers(json: false)));

  Future<dynamic> post(String path, Map<String, dynamic> body) =>
      _send((c) => c.post(Uri.parse(apiUrl(path)),
          headers: _headers(), body: jsonEncode(body)));

  Future<dynamic> delete(String path) => _send((c) =>
      c.delete(Uri.parse(apiUrl(path)), headers: _headers(json: false)));

  Future<dynamic> patch(String path, Map<String, dynamic> body) =>
      _send((c) => c.patch(Uri.parse(apiUrl(path)),
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
    final client = _client ?? http.Client();
    try {
      final streamed = await client.send(req).timeout(_timeout);
      return _decode(await http.Response.fromStream(streamed));
    } finally {
      if (_client == null) client.close();
    }
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