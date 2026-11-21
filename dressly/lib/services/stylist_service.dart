import '../models/stylist.dart';
import 'api_client.dart';

/// The personal stylist. A turn runs on the server in the background:
/// [send] returns at once, then [thread] is polled until it is no longer
/// pending.
class StylistService {
  StylistService(this._api);
  final ApiClient _api;

  Future<bool> available() async {
    final data = await _api.get('/stylist/status') as Map<String, dynamic>;
    return data['available'] == true;
  }

  Future<List<StylistThread>> threads() async {
    final data = await _api.get('/stylist/threads') as Map<String, dynamic>;
    return [
      for (final t in (data['items'] as List? ?? []))
        StylistThread.fromJson((t as Map).cast<String, dynamic>()),
    ];
  }

  Future<StylistThread> thread(int id) async => StylistThread.fromJson(
    (await _api.get('/stylist/threads/$id') as Map).cast<String, dynamic>(),
  );

  /// Send [message]; returns the thread id (a new one when [threadId] is
  /// null).
  Future<int> send(
    String message, {
    int? threadId,
    String speed = 'balanced',
    String renderTier = 'flex',
  }) async {
    final data =
        await _api.post('/stylist/chat', {
              'message': message,
              'thread_id': ?threadId,
              'speed': speed,
              'render_tier': renderTier,
            })
            as Map<String, dynamic>;
    return (data['thread_id'] as num).toInt();
  }

  /// Poll until the stylist has answered (or failed).
  Future<StylistThread> waitForReply(
    int threadId, {
    Duration every = const Duration(seconds: 1),
    Duration max = const Duration(minutes: 6),
  }) async {
    final end = DateTime.now().add(max);
    while (true) {
      await Future<void>.delayed(every);
      final t = await thread(threadId);
      if (!t.pending || DateTime.now().isAfter(end)) return t;
    }
  }

  Future<void> deleteThread(int id) => _api.delete('/stylist/threads/$id');

  /// Add a proposal to the user's outfits; returns the outfit id.
  /// Starts an AI render of a proposal; returns the new outfit's id.
  /// [person]: 'none' | 'random' | a model id.
  Future<int> renderProposal(
    int proposalId, {
    String person = 'none',
    String tier = 'flex',
  }) async {
    final data =
        await _api.post('/stylist/proposals/$proposalId/render', {
              'person': person,
              'tier': tier,
            })
            as Map<String, dynamic>;
    return (data['outfit_id'] as num).toInt();
  }

  Future<int> saveProposal(int proposalId) async {
    final data =
        await _api.post('/stylist/proposals/$proposalId/save', {})
            as Map<String, dynamic>;
    return (data['outfit_id'] as num).toInt();
  }
}
