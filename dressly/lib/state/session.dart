import 'package:flutter/foundation.dart';

import '../models/user.dart';

/// Holds the authenticated session and exposes the services wired with the
/// current token. Provided at the app root so screens can react to login/logout.
class Session extends ChangeNotifier {
  Session();

  AppUser? user;
  String? token;

  bool get isLoggedIn => user != null && token != null;

  void setSession(AppUser newUser, String newToken) {
    user = newUser;
    token = newToken;
    notifyListeners();
  }

  void logout() {
    user = null;
    token = null;
    notifyListeners();
  }
}