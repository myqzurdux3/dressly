import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:provider/provider.dart';

import '../services/api_client.dart';
import 'providers.dart';
import 'session.dart';

/// Gives every Riverpod provider below it — every route of the app, not just
/// the home shell — an [ApiClient] holding the current session's token.
///
/// Sits above `MaterialApp`: a pushed route is a child of the Navigator, not
/// of the screen that pushed it, so a scope inside the home shell would not
/// reach the garment detail.
///
/// One client per token: rebuilding with the same token (theme or locale
/// change) hands Riverpod the same instance, so nothing downstream reloads.
/// A new token replaces it, and the services depending on it follow.
class SessionApiScope extends StatefulWidget {
  const SessionApiScope({super.key, required this.child});

  final Widget child;

  @override
  State<SessionApiScope> createState() => _SessionApiScopeState();
}

class _SessionApiScopeState extends State<SessionApiScope> {
  ApiClient? _client;

  ApiClient _clientFor(String? token) {
    final c = _client;
    if (c != null && c.token == token) return c;
    return _client = ApiClient(token: token);
  }

  @override
  Widget build(BuildContext context) {
    final token = context.select<Session, String?>((s) => s.token);
    return ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(_clientFor(token))],
      child: widget.child,
    );
  }
}
