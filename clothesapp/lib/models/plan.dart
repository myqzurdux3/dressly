
/// One algorithm in a week's mix, with its own value when it needs one.
class PlanAlgoChoice {
  const PlanAlgoChoice({
    required this.algo,
    this.color = '',
    this.brand = '',
    this.tag = '',
  });

  final String algo;
  final String color;
  final String brand;
  final String tag;

  /// The argument this entry carries, whichever kind it is — for a label, and
  /// for deciding whether the entry is complete enough to send.
  String get value =>
      color.isNotEmpty ? color : (brand.isNotEmpty ? brand : tag);

  Map<String, dynamic> toJson() => {
        'algo': algo,
        'color': color,
        'brand': brand,
        'tag': tag,
      };

  factory PlanAlgoChoice.fromJson(Map<String, dynamic> j) => PlanAlgoChoice(
        algo: (j['algo'] ?? 'random') as String,
        color: (j['color'] ?? '') as String,
        brand: (j['brand'] ?? '') as String,
        tag: (j['tag'] ?? '') as String,
      );
}

/// Whether an algorithm needs an argument before it can be used, and which.
///
/// The server answers `needs: "none" | "color" | "brand" | "tag"` — the string
/// "none", not an empty one. Testing for emptiness sent every argument-free
/// algorithm down the "ask the user for a value" path, whose fallback asked for
/// a tag: ticking "Random" in the week planner popped up "Which tag?", and the
/// modes that pick their own theme (same brand, one colour, same cut, shared
/// tag, least worn) could not be added at all.
bool algoNeedsValue(String needs) {
  final n = needs.trim().toLowerCase();
  return n == 'color' || n == 'brand' || n == 'tag';
}

/// Everything the week planner asks the server for — the same questions the
/// single-outfit sheet asks, plus the mix and the repeat-theme switch.
class PlanOptions {
  const PlanOptions({
    required this.algos,
    this.weather = 'auto',
    this.categories = const [],
    this.minScore = 0,
    this.fillGaps = true,
    this.allowRepeatTheme = false,
  });

  final List<PlanAlgoChoice> algos;
  final String weather;
  final List<String> categories;
  final int minScore;
  final bool fillGaps;

  /// Off by default: a week of "same brand" that lands on one brand every day
  /// is the thing this exists to prevent.
  final bool allowRepeatTheme;

  /// What opening the planner proposes before anybody chooses: varied outfits,
  /// dressed for the forecast.
  factory PlanOptions.defaults() => const PlanOptions(
        algos: [PlanAlgoChoice(algo: 'random')],
        weather: 'auto',
        fillGaps: true,
      );
}

/// A garment as a plan card shows it: a name and a picture, nothing more.
class PlanCloth {
  PlanCloth({
    required this.id,
    required this.name,
    required this.brand,
    required this.category,
    required this.thumbUrl,
  });

  final int id;
  final String name;
  final String brand;
  final String category;
  final String thumbUrl;

  factory PlanCloth.fromJson(Map<String, dynamic> j) => PlanCloth(
        id: (j['id'] as num).toInt(),
        name: (j['name'] ?? '') as String,
        brand: (j['brand'] ?? '') as String,
        category: (j['category'] ?? '') as String,
        thumbUrl: (j['thumb_url'] ?? '') as String,
      );
}

/// One day of a proposed or saved week.
class PlanDay {
  PlanDay({
    required this.day,
    required this.clothIds,
    required this.cloths,
    this.locked = false,
    this.repeated = false,
    this.alreadyPlanned = false,
    this.rendered = false,
    this.worn = false,
    this.algo = '',
    this.theme = '',
    this.weatherMode = 'any',
    this.weatherAvailable = false,
    this.tempMax,
  });

  final String day; // 'YYYY-MM-DD'
  final List<int> clothIds;
  final List<PlanCloth> cloths;

  /// Pinned by the user: regenerating leaves it exactly as it is.
  final bool locked;

  /// The wardrobe could not dress this day without reusing something. Shown,
  /// not hidden — a plan that silently repeats looks like a bug.
  final bool repeated;

  /// The agenda already has an entry here, so applying will skip it unless the
  /// user asks to replace.
  final bool alreadyPlanned;

  final bool rendered;
  final bool worn;

  /// Which algorithm dressed this day, and the theme it landed on — shown on
  /// the card so a mixed week is readable ("same brand · ADIDAS").
  final String algo;
  final String theme;

  final String weatherMode; // 'hot' | 'cold' | 'any'
  final bool weatherAvailable;
  final double? tempMax;

  bool get isEmpty => clothIds.isEmpty;
  String get shortTemp => tempMax == null ? '' : '${tempMax!.round()}°';

  PlanDay copyWith({bool? locked}) => PlanDay(
        day: day,
        clothIds: clothIds,
        cloths: cloths,
        locked: locked ?? this.locked,
        repeated: repeated,
        alreadyPlanned: alreadyPlanned,
        rendered: rendered,
        worn: worn,
        algo: algo,
        theme: theme,
        weatherMode: weatherMode,
        weatherAvailable: weatherAvailable,
        tempMax: tempMax,
      );

  factory PlanDay.fromJson(Map<String, dynamic> j) {
    final w = (j['weather'] as Map?)?.cast<String, dynamic>() ?? const {};
    return PlanDay(
      day: (j['day'] ?? '') as String,
      clothIds: [
        for (final id in (j['cloth_ids'] as List? ?? [])) (id as num).toInt(),
      ],
      cloths: [
        for (final raw in (j['cloths'] as List? ?? []))
          PlanCloth.fromJson((raw as Map).cast<String, dynamic>()),
      ],
      locked: j['locked'] == true,
      repeated: j['repeated'] == true,
      alreadyPlanned: j['already_planned'] == true,
      rendered: j['rendered'] == true,
      worn: j['worn'] == true,
      algo: (j['algo'] ?? '') as String,
      theme: (j['theme'] ?? '') as String,
      weatherMode: (w['mode'] ?? 'any') as String,
      weatherAvailable: w['available'] == true,
      tempMax: (w['temp_max'] as num?)?.toDouble(),
    );
  }
}

/// A proposed week, or the one already in the agenda.
class WeekPlan {
  WeekPlan({required this.days, this.algo = 'random'});

  final List<PlanDay> days;
  final String algo;

  bool get isEmpty => days.every((d) => d.isEmpty);

  /// What applying would actually write: the days that have clothes and are not
  /// already spoken for.
  Map<String, List<int>> get applicable => {
        for (final d in days)
          if (d.clothIds.isNotEmpty) d.day: d.clothIds,
      };

  factory WeekPlan.fromJson(Map<String, dynamic> j) => WeekPlan(
        algo: (j['algo'] ?? 'random') as String,
        days: [
          for (final raw in (j['days'] as List? ?? []))
            PlanDay.fromJson((raw as Map).cast<String, dynamic>()),
        ],
      );
}
