/// A user report the admin reviews, from the `/notifications` router.
///
/// Two kinds share this shape:
/// - [ReportKind.cutout]: a bad background removal on a cloth photo
///   (GET /notifications). Carries the photo and can be marked as handled
///   (POST /notifications/{id}/resolve).
/// - [ReportKind.generation]: a bad or failed outfit render
///   (GET /notifications/reports). The server offers no resolve route for it.
enum ReportKind { cutout, generation }

class UserReport {
  const UserReport({
    required this.id,
    required this.kind,
    required this.message,
    required this.resolved,
    required this.createdAt,
    this.reporterEmail = '',
    this.imageUrl = '',
    this.clothName = '',
    this.tier = '',
    this.outfitId,
  });

  final int id;
  final ReportKind kind;
  final String message;
  final bool resolved;

  /// Server timestamp as sent ("2026-11-22 14:05:00", UTC).
  final String createdAt;
  final String reporterEmail;

  /// Relative image path (`/images/...`); empty when the report has none.
  final String imageUrl;
  final String clothName;

  /// Render tier of a generation report ('flex', 'pro', ...).
  final String tier;
  final int? outfitId;

  /// Only cut-out reports have a resolve route.
  bool get canResolve => kind == ReportKind.cutout && !resolved;

  /// When the report was sent, in local time; null if the text does not parse.
  DateTime? get createdAtLocal {
    final raw = createdAt.trim();
    if (raw.isEmpty) return null;
    // SQLite CURRENT_TIMESTAMP is UTC without a zone marker.
    final iso = raw.contains('T') ? raw : raw.replaceFirst(' ', 'T');
    final hasZone = iso.endsWith('Z') || RegExp(r'[+-]\d\d:?\d\d$').hasMatch(iso);
    return DateTime.tryParse(hasZone ? iso : '${iso}Z')?.toLocal();
  }

  static int _int(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
  static String _str(Object? v) => v == null ? '' : '$v';
  static bool _bool(Object? v) => v == true || v == 1 || v == '1';

  factory UserReport.cutoutFromJson(Map<String, dynamic> j) => UserReport(
        id: _int(j['id']),
        kind: ReportKind.cutout,
        message: _str(j['message']),
        resolved: _bool(j['resolved']),
        createdAt: _str(j['created_at']),
        reporterEmail: _str(j['reporter_email']),
        imageUrl: _str(j['image_url']),
        clothName: _str(j['cloth_name']),
      );

  factory UserReport.generationFromJson(Map<String, dynamic> j) => UserReport(
        id: _int(j['id']),
        kind: ReportKind.generation,
        message: _str(j['message']),
        resolved: _bool(j['resolved']),
        createdAt: _str(j['created_at']),
        reporterEmail: _str(j['reporter_email']),
        tier: _str(j['tier']),
        outfitId: j['outfit_id'] == null ? null : _int(j['outfit_id']),
      );
}
