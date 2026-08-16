import 'outfit.dart';

/// A planned outfit for a given day. [outfit] is the embedded outfit (if the
/// entry references one), already hydrated by the backend.
class AgendaEntry {
  final int id;
  final String day; // 'YYYY-MM-DD'
  final int? outfitId;
  final String title;
  final String note;
  final bool worn;
  final String? createdAt;
  final Outfit? outfit;

  AgendaEntry({
    required this.id,
    required this.day,
    required this.outfitId,
    required this.title,
    required this.note,
    required this.worn,
    this.createdAt,
    this.outfit,
  });

  factory AgendaEntry.fromJson(Map<String, dynamic> json) => AgendaEntry(
        id: json['id'] as int,
        day: (json['day'] ?? '') as String,
        outfitId: json['outfit_id'] as int?,
        title: (json['title'] ?? '') as String,
        note: (json['note'] ?? '') as String,
        worn: json['worn'] as bool? ?? false,
        createdAt: json['created_at'] as String?,
        outfit: json['outfit'] == null
            ? null
            : Outfit.fromJson(json['outfit'] as Map<String, dynamic>),
      );
}
