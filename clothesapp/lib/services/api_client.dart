import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../config/api_config.dart';

/// Thin wrapper around package:http that injects the bearer token, handles
/// JSON encode/decode, and turns non-2xx responses into typed exceptions.
class ApiClient {
  ApiClient({required this.token});

  String? token;

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

  Future<dynamic> get(String path) async {
    final resp = await http
        .get(Uri.parse(apiUrl(path)), headers: _headers(json: false))
        .timeout(_timeout);
    return _decode(resp);
  }

  Future<dynamic> post(String path, Map<String, dynamic> body) async {
    final resp = await http
        .post(Uri.parse(apiUrl(path)), headers: _headers(), body: jsonEncode(body))
        .timeout(_timeout);
    return _decode(resp);
  }

  Future<dynamic> delete(String path) async {
    final resp = await http
        .delete(Uri.parse(apiUrl(path)), headers: _headers(json: false))
        .timeout(_timeout);
    return _decode(resp);
  }

  Future<dynamic> patch(String path, Map<String, dynamic> body) async {
    final resp = await http
        .patch(Uri.parse(apiUrl(path)), headers: _headers(), body: jsonEncode(body))
        .timeout(_timeout);
    return _decode(resp);
  }

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
    final streamed = await req.send().timeout(_timeout);
    final resp = await http.Response.fromStream(streamed);
    return _decode(resp);
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
    final streamed = await req.send().timeout(_timeout);
    final resp = await http.Response.fromStream(streamed);
    return _decode(resp);
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
    final streamed = await req.send().timeout(_timeout);
    final resp = await http.Response.fromStream(streamed);
    return _decode(resp);
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
    final streamed = await req.send().timeout(_timeout);
    final resp = await http.Response.fromStream(streamed);
    return _decode(resp);
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