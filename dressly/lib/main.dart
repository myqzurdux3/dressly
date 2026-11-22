import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderScope;
import 'package:provider/provider.dart';

import 'app.dart';
import 'design/gallery/ds_gallery.dart';
import 'services/api_client.dart';
import 'services/auth_service.dart';
import 'services/image_cache_config.dart';
import 'services/pinned_http.dart';
import 'state/gen_prefs_controller.dart';
import 'state/locale_controller.dart';
import 'state/session.dart';
import 'state/theme_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (const bool.fromEnvironment('DS_GALLERY')) {
    runApp(const DsGalleryApp());
    return;
  }
  runApp(await bootstrap());
}

/// Everything [main] does before `runApp`: network setup, persisted
/// preferences and the session restore. Returns the root widget tree.
/// Split out so the on-device perf test can start the real app.
Future<Widget> bootstrap() async {
  // Must happen before the first request: the token restore below already
  // talks to the server, and image widgets create their own clients later.
  installCertificatePinning();
  AppImageCache.configureMemoryCache();

  final auth = const AuthService();
  final session = Session();
  final theme = await ThemeController.load();
  final locale = await LocaleController.load();
  final genPrefs = await GenPrefsController.load();

  // Restore the stored session. Only a refusal from the server (expired or
  // revoked token) signs the user out; with no network the last known account
  // is kept, and requests made once the connection is back succeed.
  final token = await auth.readToken();
  if (token != null) {
    try {
      session.setSession(await auth.me(token), token);
    } on ApiException catch (e) {
      if (e.statusCode == 401 || e.statusCode == 403) {
        await auth.clearToken();
      } else {
        final cached = await auth.readCachedUser();
        if (cached != null) session.setSession(cached, token);
      }
    } catch (_) {
      final cached = await auth.readCachedUser();
      if (cached != null) session.setSession(cached, token);
    }
  }

  // A token that stops being accepted mid-session (expired, or revoked by a
  // password change elsewhere) signs the user out once, back to the login.
  ApiClient.onUnauthorized = () {
    if (!session.isLoggedIn) return;
    auth.clearToken();
    rootNavigatorKey.currentState?.popUntil((r) => r.isFirst);
    session.logout();
  };

  return ProviderScope(
    child: MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: session),
        ChangeNotifierProvider.value(value: theme),
        ChangeNotifierProvider.value(value: locale),
        ChangeNotifierProvider.value(value: genPrefs),
      ],
      child: const Dressly(),
    ),
  );
}
