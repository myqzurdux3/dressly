import 'cloth.dart';

/// A garment nobody has worn in a while, and why it is on the list.
///
/// The clock starts at the last wear, or at the day the piece was added when it
/// has never been worn at all — so something photographed last week is not
/// reported as forgotten.
class DormantCloth {
  DormantCloth({
    required this.cloth,
    required this.dormantDays,
    required this.dormantSince,
    required this.neverWorn,
    required this.timesWorn,
  });

  final Cloth cloth;

  /// Days since [dormantSince]. What the list is sorted by, longest first.
  final int dormantDays;

  /// 'YYYY-MM-DD' — the last wear, or the day it entered the wardrobe.
  final String dormantSince;

  /// Never once worn, as opposed to worn and then dropped. The two read very
  /// differently to someone deciding what to let go of.
  final bool neverWorn;

  final int timesWorn;

  /// Whole months of dormancy, floored — what a label should show. Days are
  /// exact but unreadable past a few weeks ("worn 412 days ago").
  int get dormantMonths => dormantDays ~/ 30;

  factory DormantCloth.fromJson(Map<String, dynamic> j) => DormantCloth(
        cloth: Cloth.fromJson(j),
        dormantDays: (j['dormant_days'] as num?)?.toInt() ?? 0,
        dormantSince: (j['dormant_since'] ?? '') as String,
        neverWorn: j['never_worn'] == true,
        timesWorn: (j['times_worn'] as num?)?.toInt() ?? 0,
      );
}

/// The dormant list plus the totals the header needs, so the screen does not
/// have to ask twice to say "38 of 150".
class DormantReport {
  DormantReport({
    required this.months,
    required this.count,
    required this.wardrobeCount,
    required this.items,
    this.neverWornCount = 0,
    this.staleCount = 0,
    this.graceDays = 21,
  });

  /// The threshold the server actually applied (it clamps absurd values).
  final int months;

  /// Everything past the threshold — not just the page in [items].
  final int count;

  /// The two kinds, counted separately. They answer different questions: a
  /// garment never once put on is a buying mistake, one dropped six months ago
  /// is a habit. The screen heads a section with each.
  final int neverWornCount;
  final int staleCount;

  /// How long a never-worn garment is left alone before it is listed.
  final int graceDays;

  final int wardrobeCount;
  final List<DormantCloth> items;

  List<DormantCloth> get neverWorn =>
      [for (final i in items) if (i.neverWorn) i];
  List<DormantCloth> get stale => [for (final i in items) if (!i.neverWorn) i];

  bool get isEmpty => items.isEmpty;

  /// Share of the wardrobe sitting unworn, 0..100. Zero for an empty wardrobe
  /// rather than a division by nothing.
  int get percentOfWardrobe =>
      wardrobeCount == 0 ? 0 : (100 * count / wardrobeCount).round();

  factory DormantReport.fromJson(Map<String, dynamic> j) => DormantReport(
        months: (j['months'] as num?)?.toInt() ?? 6,
        count: (j['count'] as num?)?.toInt() ?? 0,
        neverWornCount: (j['never_worn_count'] as num?)?.toInt() ?? 0,
        staleCount: (j['stale_count'] as num?)?.toInt() ?? 0,
        graceDays: (j['grace_days'] as num?)?.toInt() ?? 21,
        wardrobeCount: (j['wardrobe_count'] as num?)?.toInt() ?? 0,
        items: [
          for (final raw in (j['items'] as List? ?? []))
            DormantCloth.fromJson((raw as Map).cast<String, dynamic>()),
        ],
      );
}
