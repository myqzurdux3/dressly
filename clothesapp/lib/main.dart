import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'services/auth_service.dart';
import 'state/gen_prefs_controller.dart';
import 'state/locale_controller.dart';
import 'state/session.dart';
import 'state/theme_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final auth = const AuthService();
  final session = Session();
  final theme = await ThemeController.load();
  final locale = await LocaleController.load();
  final genPrefs = await GenPrefsController.load();

  // Best-effort restore: if we have a stored token, validate it via /auth/me.
  // Failures (network down, expired token) silently fall back to the login screen.
  final token = await auth.readToken();
  if (token != null) {
    try {
      final user = await auth.me(token);
      session.setSession(user, token);
    } catch (_) {
      await auth.clearToken();
    }
  }

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: session),
        ChangeNotifierProvider.value(value: theme),
        ChangeNotifierProvider.value(value: locale),
        ChangeNotifierProvider.value(value: genPrefs),
      ],
      child: const ClothesApp(),
    ),
  );
}