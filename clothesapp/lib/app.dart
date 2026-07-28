import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'services/agenda_service.dart';
import 'services/api_client.dart';
import 'services/clothes_service.dart';
import 'services/models_service.dart';
import 'services/outfits_service.dart';
import 'services/stats_service.dart';
import 'state/gen_prefs_controller.dart';
import 'state/locale_controller.dart';
import 'state/session.dart';
import 'state/theme_controller.dart';
import 'screens/auth/login_screen.dart';
import 'screens/home/home_shell.dart';

class ClothesApp extends StatelessWidget {
  const ClothesApp({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeController>();
    final locale = context.watch<LocaleController>();
    return MaterialApp(
      title: 'Dressly',
      debugShowCheckedModeBanner: false,
      theme: theme.themeFor(Brightness.light),
      darkTheme: theme.themeFor(Brightness.dark),
      themeMode: theme.mode,
      locale: locale.locale, // null = follow the device language
      supportedLocales: LocaleController.supportedLocales,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const _AuthGate(),
    );
  }
}

/// Decides which top-level screen to show based on the session.
/// Kept as the (single, stable) `MaterialApp.home` so the Navigator doesn't
/// get rebuilt on login/logout.
class _AuthGate extends StatelessWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    return session.isLoggedIn
        ? const HomeShell()
        : const LoginScreen();
  }
}

/// Builds a ClothesService bound to the current session token.
ClothesService clothesServiceOf(BuildContext context) {
  final api = _apiFor(context);
  return ClothesService(api);
}

ModelsService modelsServiceOf(BuildContext context) {
  return ModelsService(_apiFor(context));
}

OutfitsService outfitsServiceOf(BuildContext context) {
  return OutfitsService(_apiFor(context));
}

AgendaService agendaServiceOf(BuildContext context) {
  return AgendaService(_apiFor(context));
}

StatsService statsServiceOf(BuildContext context) {
  return StatsService(_apiFor(context));
}

/// The user's outfit-generation quality preference (read once at generate time).
GenPrefsController genPrefsOf(BuildContext context) {
  return context.read<GenPrefsController>();
}

ApiClient _apiFor(BuildContext context) {
  final session = context.read<Session>();
  return ApiClient(token: session.token);
}