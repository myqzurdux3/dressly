import 'package:flutter/widgets.dart';

import '../l10n/app_text.dart';

class ClothColor {
  final int? id;
  final String color;
  final String dominance; // 'full' | 'part' | 'little'

  ClothColor({this.id, required this.color, required this.dominance});

  Map<String, dynamic> toJson() => {'color': color, 'dominance': dominance};

  factory ClothColor.fromJson(Map<String, dynamic> json) => ClothColor(
        id: json['id'] as int?,
        color: (json['color'] ?? '') as String,
        dominance: (json['dominance'] ?? 'part') as String,
      );
}

class ClothImage {
  final int id;
  final String role; // 'front' | 'back' | 'extra'
  final int sortOrder;
  final String bgAccepted; // 'pending' | 'accepted' | 'rejected'
  final String bgTolerance; // 'low' | 'medium' | 'high' removal strength
  final String originalUrl;
  final String cutoutUrl;

  /// Server-rendered, grid-sized copy of [cutoutUrl]. Empty when the backend
  /// could not produce one, in which case callers fall back to the full image.
  final String thumbUrl;
  // Enhancement (opt-in): a pending candidate awaiting accept/reject.
  final String enhancedUrl; // '' when none
  final String? enhanceStatus; // null | 'processing' | 'ready' | 'failed'
  final String enhanceMethod; // 'none' | 'auto' | 'ai' (applied to this photo)
  final String? enhancePendingMethod; // method of the pending candidate
  final String? enhanceTier; // AI tier of the pending candidate
  final String? enhanceNextTier; // next (better) AI tier, or null if top

  ClothImage({
    required this.id,
    required this.role,
    required this.sortOrder,
    required this.bgAccepted,
    this.bgTolerance = 'medium',
    required this.originalUrl,
    required this.cutoutUrl,
    this.thumbUrl = '',
    this.enhancedUrl = '',
    this.enhanceStatus,
    this.enhanceMethod = 'none',
    this.enhancePendingMethod,
    this.enhanceTier,
    this.enhanceNextTier,
  });

  factory ClothImage.fromJson(Map<String, dynamic> json) => ClothImage(
        id: json['id'] as int,
        role: (json['role'] ?? 'extra') as String,
        sortOrder: (json['sort_order'] ?? 0) as int,
        bgAccepted: (json['bg_accepted'] ?? 'pending') as String,
        bgTolerance: (json['bg_tolerance'] ?? 'medium') as String,
        originalUrl: (json['original_url'] ?? '') as String,
        cutoutUrl: (json['cutout_url'] ?? '') as String,
        thumbUrl: (json['thumb_url'] ?? '') as String,
        enhancedUrl: (json['enhanced_url'] ?? '') as String,
        enhanceStatus: json['enhance_status'] as String?,
        enhanceMethod: (json['enhance_method'] ?? 'none') as String,
        enhancePendingMethod: json['enhance_pending_method'] as String?,
        enhanceTier: json['enhance_tier'] as String?,
        enhanceNextTier: json['enhance_next_tier'] as String?,
      );

  /// The URL the UI should render for this image. If the user rejected the
  /// automatic background removal, fall back to the *original* photo
  /// regardless of what the server returned for `cutoutUrl` — this keeps
  /// the client contract explicit and immune to any backend URL aliasing.
  String? get displayUrl {
    if (bgAccepted == 'rejected') return originalUrl;
    return cutoutUrl.isNotEmpty ? cutoutUrl : originalUrl;
  }

  /// Small copy for grids and list rows. Falls back to [displayUrl] when the
  /// server has no thumbnail for this image, so callers never need to check.
  String? get thumbnailUrl => thumbUrl.isNotEmpty ? thumbUrl : displayUrl;
}

class Cloth {
  final int id;
  final int userId;
  final String name;
  final String brand;
  final String cut; // 'slim' | 'normal' | 'large' | 'oversize'
  final String category;
  final List<String> customTags;
  final List<ClothColor> colors;
  final List<ClothImage> images;
  final int score; // 0 = unrated, 1..5 = user rating
  final String? lastWornAt; // null = never worn; else 'YYYY-MM-DD'
  final bool isFavorite; // favorite cloth (independent of outfit favorites)
  final bool excludeFromAlgo; // skip this cloth in generation algorithms
  final String? createdAt;
  final String? updatedAt;

  Cloth({
    required this.id,
    required this.userId,
    required this.name,
    required this.brand,
    required this.cut,
    required this.category,
    required this.customTags,
    required this.colors,
    required this.images,
    this.score = 0,
    this.lastWornAt,
    this.isFavorite = false,
    this.excludeFromAlgo = false,
    this.createdAt,
    this.updatedAt,
  });

  /// First image — the front — by sort_order, using its displayUrl so a
  /// rejected image correctly falls back to the original photo.
  String? get displayImageUrl => _frontImage?.displayUrl;

  /// Grid-sized variant of [displayImageUrl] — what the wardrobe cards should
  /// request, so scrolling does not pull a full-resolution photo per card.
  String? get thumbImageUrl => _frontImage?.thumbnailUrl;

  /// Copy with individual fields overridden. Lets a screen patch one card
  /// locally after a toggle instead of refetching the whole paged list.
  Cloth copyWith({
    String? name,
    String? brand,
    String? cut,
    String? category,
    List<String>? customTags,
    List<ClothColor>? colors,
    List<ClothImage>? images,
    int? score,
    String? lastWornAt,
    bool? isFavorite,
    bool? excludeFromAlgo,
  }) =>
      Cloth(
        id: id,
        userId: userId,
        name: name ?? this.name,
        brand: brand ?? this.brand,
        cut: cut ?? this.cut,
        category: category ?? this.category,
        customTags: customTags ?? this.customTags,
        colors: colors ?? this.colors,
        images: images ?? this.images,
        score: score ?? this.score,
        lastWornAt: lastWornAt ?? this.lastWornAt,
        isFavorite: isFavorite ?? this.isFavorite,
        excludeFromAlgo: excludeFromAlgo ?? this.excludeFromAlgo,
        createdAt: createdAt,
        updatedAt: updatedAt,
      );

  ClothImage? get _frontImage {
    if (images.isEmpty) return null;
    final sorted = [...images]..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return sorted.first;
  }

  factory Cloth.fromJson(Map<String, dynamic> json) => Cloth(
        id: json['id'] as int,
        userId: json['user_id'] as int? ?? 0,
        name: (json['name'] ?? '') as String,
        brand: (json['brand'] ?? '') as String,
        cut: (json['cut'] ?? 'normal') as String,
        category: (json['category'] ?? '') as String,
        customTags: (json['custom_tags'] as List?)
                ?.map((e) => e.toString())
                .toList() ??
            const [],
        colors: (json['colors'] as List?)
                ?.map((e) => ClothColor.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        score: json['score'] as int? ?? 0,
        lastWornAt: json['last_worn_at'] as String?,
        isFavorite: json['is_favorite'] as bool? ?? false,
        excludeFromAlgo: json['exclude_from_algo'] as bool? ?? false,
        images: (json['images'] as List?)
                ?.map((e) => ClothImage.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        createdAt: json['created_at'] as String?,
        updatedAt: json['updated_at'] as String?,
      );
}

const List<String> kCutOptions = ['slim', 'normal', 'large', 'oversize'];
const List<String> kColorPalette = [
  'Black',
  'White',
  'Grey',
  'Blue',
  'Red',
  'Green',
  'Yellow',
  'Beige',
  'Brown',
  'Orange',
  'Purple',
  'Pink',
];
const List<String> kDominanceTiers = ['full', 'part', 'little'];

/// Fixed clothing categories the user can pick from (no free text).
const List<String> kCategoryOptions = [
  'tshirt',
  'shirt',
  'polo',
  'tank-top',
  'hoodie',
  'sweatshirt',
  'jacket',
  'jeans',
  'trousers',
  'jogging',
  'shorts',
  'shoes',
  'hat',
  'cap',
  'bag',
  'socks',
  'underwear',
];

/// Categories photographed from arbitrary angles rather than a front + back
/// pair. They need only one photo and accept any number of extra angle shots
/// (top, sole, side, detail…). Must mirror the backend's `is_multi_angle`.
const Set<String> kMultiAngleCategories = {
  'sneakers',
  'shoes',
  'hat',
  'cap',
  'bag',
  'socks',
  'underwear',
};

bool isMultiAngleCategory(String? category) =>
    category != null && kMultiAngleCategories.contains(category);

/// Categories with no meaningful garment "cut" (slim / normal / large /
/// oversize) — shoes, bags, hats, socks, etc. The Cut selector is hidden for
/// these, and the same-cut algorithm ignores them. Mirrors the backend.
const Set<String> kNoCutCategories = {
  'sneakers',
  'shoes',
  'hat',
  'cap',
  'bag',
  'socks',
  'underwear',
};

bool categoryHasCut(String? category) =>
    category != null &&
    category.isNotEmpty &&
    !kNoCutCategories.contains(category);

/// The outfit "slots" a category occupies. Two clothes can't go in the same
/// outfit when their slot sets overlap — so jeans and joggers (both `bottom`)
/// clash, a dress fills `top`+`bottom`, and a hat and a cap are both `headwear`
/// (while a hat and a bag don't clash). Layering is allowed: a top is `top`
/// and a jacket is `outer`, so they coexist.
Set<String> outfitSlots(String category) {
  // Upper body is split into layers so an outfit can legitimately stack a base
  // (t-shirt), a mid layer (hoodie/sweatshirt) and an outer (jacket) — two of
  // the SAME layer still conflict (no two t-shirts, no two hoodies).
  const base = {'tshirt', 'shirt', 'polo', 'tank-top'};
  const mid = {'hoodie', 'sweatshirt'};
  const outers = {'jacket', 'coat'};
  const bottoms = {'jeans', 'trousers', 'jogging', 'shorts', 'skirt'};
  if (base.contains(category)) return {'top'};
  if (mid.contains(category)) return {'mid'};
  if (outers.contains(category)) return {'outer'};
  if (bottoms.contains(category)) return {'bottom'};
  if (category == 'dress') return {'top', 'mid', 'bottom'}; // fills the whole body
  if (category == 'sneakers' || category == 'shoes') return {'feet'};
  if (category == 'hat' || category == 'cap') return {'headwear'};
  if (category.isEmpty) return {};
  return {category}; // socks, underwear, bag — each its own unique slot
}

/// True for upper-body garments (base top, mid layer, or outer) — the ones the
/// "which top to render" chooser lets you pick between.
bool isUpperBody(String category) {
  final s = outfitSlots(category);
  return s.contains('top') || s.contains('mid') || s.contains('outer');
}


/// Whether two categories can't coexist in one outfit (overlapping slots).
bool outfitCategoriesConflict(String a, String b) =>
    outfitSlots(a).intersection(outfitSlots(b)).isNotEmpty;

/// Rank of a category by where it sits on the body, head (small) → feet (large).
/// Sorting an outfit's items by this puts top-of-body items first and shoes
/// last, so a list reads head-to-toe.
int bodyOrder(String category) {
  const tops = {'tshirt', 'shirt', 'polo', 'tank-top', 'hoodie', 'sweatshirt'};
  const outers = {'jacket', 'coat'};
  const bottoms = {'jeans', 'trousers', 'jogging', 'shorts', 'skirt'};
  if (category == 'hat' || category == 'cap') return 0; // head
  if (tops.contains(category)) return 10; // torso
  if (outers.contains(category)) return 12;
  if (category == 'dress') return 11;
  if (category == 'bag') return 15; // carried, around the torso
  if (bottoms.contains(category)) return 20; // legs
  if (category == 'underwear') return 25;
  if (category == 'socks') return 30;
  if (category == 'sneakers' || category == 'shoes') return 40; // feet
  return 50; // unknown → last
}

/// Human label for the shared slot of two conflicting categories (for messages).
String outfitSlotLabel(String category) {
  final s = outfitSlots(category);
  if (s.contains('top') && s.contains('bottom')) return 'full outfit';
  if (s.contains('top')) return 'top';
  if (s.contains('mid')) return 'sweater/hoodie';
  if (s.contains('outer')) return 'jacket/coat';
  if (s.contains('bottom')) return 'bottom';
  if (s.contains('feet')) return 'pair of shoes';
  if (s.contains('headwear')) return 'hat';
  return categoryLabel(category).toLowerCase();
}

/// Common clothing brands used to auto-detect a brand from a cloth's name.
/// Multi-word entries are matched as a substring; single words as whole words.
const List<String> kKnownBrands = [
  'Nike', 'Adidas', 'Puma', 'Reebok', 'New Balance', 'Converse', 'Vans',
  'Under Armour', 'Asics', 'Fila', 'Champion', 'Jordan', 'Kappa',
  'Zara', 'H&M', 'Uniqlo', 'Gap', 'Mango', 'Bershka', 'Pull&Bear',
  'Levi\'s', 'Lacoste', 'Ralph Lauren', 'Tommy Hilfiger', 'Calvin Klein',
  'Gucci', 'Prada', 'Balenciaga', 'Burberry', 'Versace', 'Stussy', 'Supreme',
  'Carhartt', 'The North Face', 'Patagonia', 'Columbia', 'Dickies',
  'Timberland', 'Dr. Martens', 'Guess', 'Diesel', 'Hollister', 'Superdry',
  'Jack & Jones', 'Nautica', 'Ellesse', 'Umbro',
];

/// If a known brand (or one of [extra], e.g. the user's existing brands) appears
/// in [name], return its canonical spelling; otherwise null.
String? detectBrandInName(String name, {Iterable<String> extra = const []}) {
  final lower = name.toLowerCase();
  if (lower.trim().isEmpty) return null;
  final words = lower
      .split(RegExp(r"[^a-z0-9&'-]+"))
      .where((w) => w.isNotEmpty)
      .toSet();
  for (final b in [...kKnownBrands, ...extra]) {
    final bl = b.toLowerCase();
    if (bl.isEmpty) continue;
    final hit = bl.contains(' ') ? lower.contains(bl) : words.contains(bl);
    if (hit) return b;
  }
  return null;
}

/// Keyword → category rules for auto-detecting a garment type from its name,
/// in priority order (first match wins). More specific entries come first so
/// "t shirt" / "polo shirt" beat the generic "shirt", and "sweatpants" (jogging)
/// beats "sweat" (sweatshirt). Keywords are already normalised (lowercase,
/// accents folded, no punctuation); multi-word keywords match as a phrase,
/// single words match whole-word. English + common French terms. Every category
/// here exists in [kCategoryOptions] so it's a valid dropdown value.
const List<MapEntry<String, List<String>>> _kCategoryKeywords = [
  MapEntry('tank-top', ['tank top', 'tanktop', 'debardeur']),
  MapEntry('tshirt', ['t shirt', 'tshirt', 'tee shirt', 'tee', 'tees']),
  MapEntry('polo', ['polo']),
  MapEntry('hoodie', ['hoodie', 'hoody', 'hooded', 'capuche']),
  MapEntry('sweatshirt',
      ['sweatshirt', 'sweat shirt', 'sweat', 'sweater', 'pull', 'pullover', 'jumper']),
  // Generic "shirt" sits here — above shorts/pants so "short sleeve shirt" and
  // "long sleeve shirt" resolve to a shirt, but below the specific tops above so
  // "t shirt" / "polo shirt" / "sweat shirt" still win.
  MapEntry('shirt', ['shirt', 'chemise']),
  MapEntry('jogging', [
    'jogging', 'joggers', 'jogger', 'sweatpants', 'sweat pants',
    'track pants', 'trackpants', 'survetement', 'survet', 'jogg'
  ]),
  MapEntry('jeans', ['jeans', 'jean', 'denim']),
  MapEntry('shorts', ['shorts', 'short']),
  MapEntry('trousers',
      ['trousers', 'trouser', 'pants', 'pant', 'pantalon', 'chino', 'chinos', 'slacks']),
  MapEntry('jacket', [
    'jacket', 'veste', 'blazer', 'coat', 'manteau', 'parka', 'anorak',
    'bomber', 'windbreaker'
  ]),
  MapEntry('shoes', [
    'shoes', 'shoe', 'sneakers', 'sneaker', 'trainers', 'trainer',
    'chaussures', 'chaussure', 'basket', 'baskets', 'boots', 'boot',
    'loafers', 'sandals', 'sandal'
  ]),
  MapEntry('cap', ['cap', 'casquette']),
  MapEntry('hat', ['hat', 'beanie', 'bonnet', 'chapeau']),
  MapEntry('bag', ['bag', 'sac', 'backpack', 'handbag', 'tote', 'sac a dos']),
  MapEntry('socks', ['socks', 'sock', 'chaussette', 'chaussettes']),
  MapEntry('underwear', ['underwear', 'boxer', 'boxers', 'briefs', 'calecon', 'sous vetement']),
];

const Map<String, String> _kAccentFolds = {
  'à': 'a', 'â': 'a', 'ä': 'a', 'á': 'a', 'ã': 'a',
  'ç': 'c',
  'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e',
  'î': 'i', 'ï': 'i', 'í': 'i',
  'ô': 'o', 'ö': 'o', 'ó': 'o', 'õ': 'o',
  'û': 'u', 'ù': 'u', 'ü': 'u', 'ú': 'u',
  'ñ': 'n',
};

/// Lowercase, fold accents, and reduce punctuation to single spaces so keyword
/// matching is robust to "t-shirt" vs "t shirt" and "débardeur" vs "debardeur".
String _normalizeForMatch(String s) {
  var out = s.toLowerCase();
  _kAccentFolds.forEach((k, v) => out = out.replaceAll(k, v));
  return out.replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
}

/// If a known garment type appears in [name], return its category (a value in
/// [kCategoryOptions]); otherwise null. E.g. "black t shirt" → 'tshirt',
/// "Nike joggers" → 'jogging', "sac à dos" → 'bag'.
String? detectCategoryInName(String name) {
  final norm = _normalizeForMatch(name);
  if (norm.isEmpty) return null;
  final words = norm.split(' ').where((w) => w.isNotEmpty).toSet();
  final padded = ' $norm ';
  for (final entry in _kCategoryKeywords) {
    for (final kw in entry.value) {
      final hit =
          kw.contains(' ') ? padded.contains(' $kw ') : words.contains(kw);
      if (hit) return entry.key;
    }
  }
  return null;
}

/// Translated display name for a palette color. The stored value stays English
/// (the backend and filters use it); this only affects what the user sees.
String colorName(BuildContext context, String raw) {
  final key = 'color.${raw.toLowerCase()}';
  final t = tr(context, key);
  return t == key ? raw : t;
}

String cutLabel(BuildContext context, String cut) {
  const known = {'slim', 'normal', 'large', 'oversize'};
  return known.contains(cut) ? tr(context, 'cut.$cut') : cut;
}

String dominanceLabel(BuildContext context, String d) {
  const known = {'full', 'part', 'little'};
  return known.contains(d) ? tr(context, 'dom.$d') : d;
}

String categoryLabel(String c) {
  if (c.isEmpty) return '';
  if (c == 'tshirt') return 'T-shirt';
  if (c == 'tank-top') return 'Tank top';
  // Capitalize first letter of each word (handles 't-shirt' etc.).
  return c
      .split('-')
      .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
      .join(' ');
}

/// Translated display name for a garment category (e.g. 'tshirt' → "T-shirt" /
/// "T-shirt", 'jacket' → "Jacket" / "Veste"). The stored value stays the raw
/// English key; this only affects what the user sees. Falls back to the English
/// [categoryLabel] for any category without a translation.
String categoryName(BuildContext context, String c) {
  if (c.isEmpty) return '';
  final key = 'cat.$c';
  final t = tr(context, key);
  return t == key ? categoryLabel(c) : t;
}