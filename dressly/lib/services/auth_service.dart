import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/api_config.dart';
import '../models/user.dart';
import 'api_client.dart';
import 'pinned_http.dart';

const _kTokenKey = 'auth_token';
// Last known account, so a launch without network keeps the session instead
// of dropping to the login screen.
const _kUserKey = 'auth_user';

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
    await prefs.remove(_kUserKey);
  }

  Future<AppUser?> readCachedUser() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kUserKey);
    if (raw == null) return null;
    try {
      return AppUser.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveUser(AppUser user) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kUserKey, jsonEncode(user.toJson()));
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
    final res = await _post('/auth/password', {
      'current_password': currentPassword,
      'new_password': newPassword,
    }, token: token);
    final fresh = res['token'] as String;
    final user = AppUser.fromJson(res['user'] as Map<String, dynamic>);
    await _saveToken(fresh);
    await _saveUser(user);
    return (user: user, token: fresh);
  }

  /// Set (or clear, with an empty [username]) the name this account signs in
  /// with. Returns the updated user.
  Future<AppUser> changeUsername(String token, String username) async {
    final user = AppUser.fromJson(await _post('/auth/username', {
      'username': username,
    }, token: token));
    await _saveUser(user);
    return user;
  }

  Future<({AppUser user, String token})> signup(
    String email,
    String password,
  ) async {
    final res = await _post('/auth/signup', {
      'email': email,
      'password': password,
    });
    final token = res['token'] as String;
    final user = AppUser.fromJson(res['user']);
    await _saveToken(token);
    await _saveUser(user);
    return (user: user, token: token);
  }

  Future<({AppUser user, String token})> login(
    String email,
    String password,
  ) async {
    final res = await _post('/auth/login', {
      'email': email,
      'password': password,
    });
    final token = res['token'] as String;
    final user = AppUser.fromJson(res['user']);
    await _saveToken(token);
    await _saveUser(user);
    return (user: user, token: token);
  }

  Future<AppUser> me(String token) async {
    final user = AppUser.fromJson(await _get('/auth/me', token));
    await _saveUser(user);
    return user;
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body, {
    String? token,
  }) async {
    // The shared API client, not a bare http.post: same connection pool, same
    // certificate pinning, same timeouts as every other call.
    try {
      final resp = await PinnedHttp.api
          .post(
            Uri.parse(apiUrl(path)),
            headers: {
              'Content-Type': 'application/json',
              if (token != null) 'Authorization': 'Bearer $token',
            },
            body: jsonEncode(body),
          )
          .timeout(ApiClient.timeoutFor(path));
      return _decode(resp);
    } catch (e) {
      throw ApiClient.friendly(e);
    }
  }

  Future<Map<String, dynamic>> _get(String path, String token) async {
    // Same pool and same deadline as _post and as ApiClient. me() runs at
    // startup to restore the session, so a bare http.get with no timeout meant
    // one stalled socket held the launch screen open indefinitely.
    try {
      final resp = await PinnedHttp.api
          .get(
            Uri.parse(apiUrl(path)),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(ApiClient.timeoutFor(path));
      return _decode(resp);
    } catch (e) {
      throw ApiClient.friendly(e);
    }
  }

  static Map<String, dynamic> _decode(http.Response resp) =>
      (ApiClient.decodeResponse(resp) as Map<String, dynamic>?) ?? {};
}
