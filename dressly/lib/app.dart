import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

import 'services/admin_service.dart';
import 'services/agenda_service.dart';
import 'services/clothes_service.dart';
import 'services/models_service.dart';
import 'services/outfits_service.dart';
import 'services/plan_service.dart';
import 'services/stylist_service.dart';
import 'services/stats_service.dart';
import 'services/weather_service.dart';
import 'state/gen_prefs_controller.dart';
import 'state/locale_controller.dart';
import 'state/providers.dart';
import 'screens/auth/login_screen.dart';
import 'screens/home/home_shell.dart';

class Dressly extends ConsumerWidget {
  const Dressly({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ref.watch(themeControllerProvider);
    final locale = ref.watch(localeControllerProvider);
    return MaterialApp(
      navigatorKey: rootNavigatorKey,
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

/// Lets code outside the widget tree (the sign-out on an expired token)
/// close pushed screens before the auth gate swaps to the login screen.
final rootNavigatorKey = GlobalKey<NavigatorState>();

/// Decides which top-level screen to show based on the session.
/// Kept as the (single, stable) `MaterialApp.home` so the Navigator doesn't
/// get rebuilt on login/logout.
class _AuthGate extends ConsumerWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    return session.isLoggedIn ? const HomeShell() : const LoginScreen();
  }
}

// Context helpers for widgets without a `ref`: each one reads the matching
// Riverpod provider (lib/state/providers.dart), the single source of truth.
// Read, not watched: callers fetch at the time of the call, as before.

T _read<T>(BuildContext context, ProviderListenable<T> provider) =>
    ProviderScope.containerOf(context, listen: false).read(provider);

/// The ClothesService bound to the current session token.
ClothesService clothesServiceOf(BuildContext context) =>
    _read(context, clothesServiceProvider);

ModelsService modelsServiceOf(BuildContext context) =>
    _read(context, modelsServiceProvider);

OutfitsService outfitsServiceOf(BuildContext context) =>
    _read(context, outfitsServiceProvider);

AgendaService agendaServiceOf(BuildContext context) =>
    _read(context, agendaServiceProvider);

StatsService statsServiceOf(BuildContext context) =>
    _read(context, statsServiceProvider);

WeatherService weatherServiceOf(BuildContext context) =>
    _read(context, weatherServiceProvider);

StylistService stylistServiceOf(BuildContext context) =>
    _read(context, stylistServiceProvider);

PlanService planServiceOf(BuildContext context) =>
    _read(context, planServiceProvider);

AdminService adminServiceOf(BuildContext context) =>
    _read(context, adminServiceProvider);

/// The user's outfit-generation quality preference (read once at generate time).
GenPrefsController genPrefsOf(BuildContext context) =>
    _read(context, genPrefsProvider);
