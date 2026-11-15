import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/api_client.dart';
import '../services/clothes_service.dart';

/// The authenticated API client, provided by `SessionApiScope` above
/// `MaterialApp` with the current session's token.
final apiClientProvider = Provider<ApiClient>(
  (ref) => throw UnimplementedError(
    'apiClientProvider is provided by SessionApiScope; read it below it',
  ),
  // Scoped: overridden in a nested ProviderScope, so it and everything that
  // depends on it must declare dependencies.
  dependencies: const [],
);

final clothesServiceProvider = Provider<ClothesService>(
  (ref) => ClothesService(ref.watch(apiClientProvider)),
  dependencies: [apiClientProvider],
);
