import 'plan.dart';

/// An outfit the stylist recommended, shown as a card the user can save.
class StylistProposal {
  StylistProposal({
    required this.id,
    required this.title,
    required this.reason,
    required this.clothIds,
    required this.cloths,
    this.outfitId,
    this.renderId,
  });

  final int id;
  final String title;
  final String reason;
  final List<int> clothIds;
  final List<PlanCloth> cloths;

  /// Set once saved to the user's outfits.
  final int? outfitId;

  /// The AI render started from it, if any.
  final int? renderId;

  StylistProposal saved(int outfitId) => StylistProposal(
    id: id,
    title: title,
    reason: reason,
    clothIds: clothIds,
    cloths: cloths,
    outfitId: outfitId,
    renderId: renderId,
  );

  StylistProposal rendered(int renderId) => StylistProposal(
    id: id,
    title: title,
    reason: reason,
    clothIds: clothIds,
    cloths: cloths,
    outfitId: outfitId,
    renderId: renderId,
  );

  factory StylistProposal.fromJson(Map<String, dynamic> j) => StylistProposal(
    id: (j['id'] as num).toInt(),
    title: (j['title'] ?? '') as String,
    reason: (j['reason'] ?? '') as String,
    clothIds: [
      for (final id in (j['cloth_ids'] as List? ?? [])) (id as num).toInt(),
    ],
    cloths: [
      for (final c in (j['cloths'] as List? ?? []))
        PlanCloth.fromJson((c as Map).cast<String, dynamic>()),
    ],
    outfitId: (j['outfit_id'] as num?)?.toInt(),
    renderId: (j['render_id'] as num?)?.toInt(),
  );
}

class StylistMessage {
  StylistMessage({
    required this.id,
    required this.role,
    required this.text,
    this.proposals = const [],
  });

  final int id;
  final String role; // 'user' | 'assistant'
  final String text;
  final List<StylistProposal> proposals;

  bool get isUser => role == 'user';

  factory StylistMessage.fromJson(Map<String, dynamic> j) => StylistMessage(
    id: (j['id'] as num).toInt(),
    role: (j['role'] ?? 'assistant') as String,
    text: (j['text'] ?? '') as String,
    proposals: [
      for (final p in (j['proposals'] as List? ?? []))
        StylistProposal.fromJson((p as Map).cast<String, dynamic>()),
    ],
  );
}

class StylistThread {
  StylistThread({
    required this.id,
    required this.title,
    this.messages = const [],
    this.pending = false,
    this.error = '',
    this.updatedAt = '',
  });

  final int id;
  final String title;
  final List<StylistMessage> messages;

  /// The stylist is still answering.
  final bool pending;

  /// Why the last turn failed; empty when it did not.
  final String error;
  final String updatedAt;

  factory StylistThread.fromJson(Map<String, dynamic> j) => StylistThread(
    id: (j['id'] as num).toInt(),
    title: (j['title'] ?? '') as String,
    pending: j['pending'] == true,
    error: (j['error'] ?? '') as String,
    updatedAt: (j['updated_at'] ?? '') as String,
    messages: [
      for (final m in (j['messages'] as List? ?? []))
        StylistMessage.fromJson((m as Map).cast<String, dynamic>()),
    ],
  );
}
