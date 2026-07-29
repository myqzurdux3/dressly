import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/api_config.dart';
import '../models/user.dart';
import 'pinned_http.dart';

const _kTokenKey = 'auth_token';

class AuthService {
  const AuthService();

  Future<String?> readToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kTokenKey);
  }

  Future<void> _saveToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kTokenKey, token);
  }

  Future<void> clearToken() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kTokenKey);
  }

  /// Change the signed-in user's password.
  ///
  /// Returns a fresh token: the server ends every session opened before the
  /// change, including the caller's own, and hands back a replacement so the
  /// user is not signed out by their own action.
  Future<({AppUser user, String token})> changePassword(
    String token, {
    required String currentPassword,
    required String newPassword,
  }) async {
    final res = await _post(
      '/auth/password',
      {'current_password': currentPassword, 'new_password': newPassword},
      token: token,
    );
    final fresh = res['token'] as String;
    await _saveToken(fresh);
    return (
      user: AppUser.fromJson(res['user'] as Map<String, dynamic>),
      token: fresh,
    );
  }

  Future<({AppUser user, String token})> signup(
      String email, String password) async {
    final res = await _post('/auth/signup', {
      'email': email,
      'password': password,
    });
    final token = res['token'] as String;
    await _saveToken(token);
    return (user: AppUser.fromJson(res['user']), token: token);
  }

  Future<({AppUser user, String token})> login(
      String email, String password) async {
    final res = await _post('/auth/login', {
      'email': email,
      'password': password,
    });
    final token = res['token'] as String;
    await _saveToken(token);
    return (user: AppUser.fromJson(res['user']), token: token);
  }

  Future<AppUser> me(String token) async {
    final res = await _get('/auth/me', token);
    return AppUser.fromJson(res);
  }

  Future<Map<String, dynamic>> _post(
      String path, Map<String, dynamic> body, {String? token}) async {
    // The shared API client, not a bare http.post: same connection pool, same
    // certificate pinning, same timeouts as every other call.
    final resp = await PinnedHttp.api.post(
      Uri.parse(apiUrl(path)),
      headers: {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      },
      body: jsonEncode(body),
    );
    return _decode(resp);
  }

  Future<Map<String, dynamic>> _get(String path, String token) async {
    final resp = await http.get(
      Uri.parse(apiUrl(path)),
      headers: {'Authorization': 'Bearer $token'},
    );
    return _decode(resp);
  }

  Map<String, dynamic> _decode(http.Response resp) {
    if (resp.statusCode >= 400) {
      String detail = 'Request failed (${resp.statusCode})';
      try {
        final body = jsonDecode(resp.body);
        if (body is Map && body['detail'] != null) {
          detail = body['detail'].toString();
        }
      } catch (_) {}
      throw Exception(detail);
    }
    if (resp.body.isEmpty) return {};
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }
}