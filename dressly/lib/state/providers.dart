import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart' show ChangeNotifierProvider;

import '../services/admin_service.dart';
import '../services/agenda_service.dart';
import '../services/api_client.dart';
import '../services/clothes_service.dart';
import '../services/models_service.dart';
import '../services/outfits_service.dart';
import '../services/plan_service.dart';
import '../services/stats_service.dart';
import '../services/stylist_service.dart';
import '../services/weather_service.dart';
import 'gen_prefs_controller.dart';
import 'locale_controller.dart';
import 'session.dart';
import 'theme_controller.dart';

// The app-wide ChangeNotifiers. `bootstrap()` creates and loads them before
// `runApp`, then hands them to the root ProviderScope with `overrideWith`.
// They are owned by bootstrap (or by the test that built them), so Riverpod
// never disposes them: `disposeNotifier: false`, like `.value` in provider.

Never _notProvided(String what) => throw UnimplementedError(
  '$what is provided by the root ProviderScope (see bootstrap); '
  'override it in tests',
);

final sessionProvider = ChangeNotifierProvider<Session>(
  (ref) => _notProvided('sessionProvider'),
  disposeNotifier: false,
);

final themeControllerProvider = ChangeNotifierProvider<ThemeController>(
  (ref) => _notProvided('themeControllerProvider'),
  disposeNotifier: false,
);

final localeControllerProvider = ChangeNotifierProvider<LocaleController>(
  (ref) => _notProvided('localeControllerProvider'),
  disposeNotifier: false,
);

final genPrefsProvider = ChangeNotifierProvider<GenPrefsController>(
  (ref) => _notProvided('genPrefsProvider'),
  disposeNotifier: false,
);

/// The authenticated API client, holding the current session's token.
///
/// One client per token: the session notifying for anything else (same
/// token) keeps the very same instance, so nothing downstream reloads. A new
/// token replaces it, and the services depending on it follow.
final apiClientProvider = Provider<ApiClient>((ref) {
  final token = ref.watch(sessionProvider.select((s) => s.token));
  return ApiClient(token: token);
});

// One provider per service, all bound to [apiClientProvider]. Widgets without
// a `ref` reach them through the `xxxServiceOf(context)` helpers in app.dart.

final clothesServiceProvider = Provider<ClothesService>(
  (ref) => ClothesService(ref.watch(apiClientProvider)),
);

final modelsServiceProvider = Provider<ModelsService>(
  (ref) => ModelsService(ref.watch(apiClientProvider)),
);

final outfitsServiceProvider = Provider<OutfitsService>(
  (ref) => OutfitsService(ref.watch(apiClientProvider)),
);

final agendaServiceProvider = Provider<AgendaService>(
  (ref) => AgendaService(ref.watch(apiClientProvider)),
);

final statsServiceProvider = Provider<StatsService>(
  (ref) => StatsService(ref.watch(apiClientProvider)),
);

final weatherServiceProvider = Provider<WeatherService>(
  (ref) => WeatherService(ref.watch(apiClientProvider)),
);

final stylistServiceProvider = Provider<StylistService>(
  (ref) => StylistService(ref.watch(apiClientProvider)),
);

final planServiceProvider = Provider<PlanService>(
  (ref) => PlanService(ref.watch(apiClientProvider)),
);

final adminServiceProvider = Provider<AdminService>(
  (ref) => AdminService(ref.watch(apiClientProvider)),
);
