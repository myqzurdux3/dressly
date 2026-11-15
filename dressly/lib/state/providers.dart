import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/api_client.dart';
import '../services/clothes_service.dart';

/// The authenticated API client. Only exists below `HomeShell`, which
/// overrides it with the logged-in session's token (and rebuilds the scope
/// when the token changes, so a new login never reuses the old client).
final apiClientProvider = Provider<ApiClient>(
  (ref) => throw UnimplementedError(
    'apiClientProvider is overridden in HomeShell; read it below the shell',
  ),
  // Scoped: overridden in a nested ProviderScope, so it and everything that
  // depends on it must declare dependencies.
  dependencies: const [],
);

final clothesServiceProvider = Provider<ClothesService>(
  (ref) => ClothesService(ref.watch(apiClientProvider)),
  dependencies: [apiClientProvider],
);
