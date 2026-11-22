import 'api_client.dart';

/// True for a failure that never reached the server (no connection, timeout):
/// [ApiClient.friendly] maps those to status 0.
bool isTransportError(Object e) => e is ApiException && e.statusCode == 0;

/// Calls [fetch] every [every] until [isDone] holds, [maxRounds] is reached,
/// or [cancelled] says the caller is gone. Returns the latest value fetched,
/// or [initial] when nothing was fetched yet.
///
/// Two failure modes this guards against:
/// - a screen that closes mid-wait used to keep polling for minutes; callers
///   now pass `cancelled: () => !mounted`;
/// - a single dropped request (a phone switching networks) used to abandon a
///   render that was still running fine. Up to [maxTransportErrors]
///   consecutive transport failures are tolerated; any other error, or one
///   more transport failure, is rethrown.
Future<T> pollUntil<T>({
  required Future<T> Function() fetch,
  required bool Function(T value) isDone,
  required T initial,
  required Duration every,
  required int maxRounds,
  bool Function()? cancelled,
  int maxTransportErrors = 3,
}) async {
  var last = initial;
  var failures = 0;
  for (var round = 0; round < maxRounds; round++) {
    await Future<void>.delayed(every);
    if (cancelled?.call() ?? false) return last;
    try {
      last = await fetch();
      failures = 0;
    } catch (e) {
      if (!isTransportError(e) || ++failures >= maxTransportErrors) rethrow;
      continue;
    }
    if (isDone(last)) return last;
  }
  return last;
}
