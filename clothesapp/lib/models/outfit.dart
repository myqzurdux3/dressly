import '../config/api_config.dart';

/// Full URL for displaying the outfit image. Includes a cache-busting query
/// string that changes when the tier / view / state change, so the platform
/// image cache can't serve a stale image after a regenerate.
String outfitImageUrl(Outfit o) => _bust(o, o.generatedUrl);

/// Grid-sized variant of [outfitImageUrl]. Falls back to the full render when
/// the server has no thumbnail, so callers never need to check.
String outfitThumbUrl(Outfit o) =>
    o.thumbUrl.isEmpty ? outfitImageUrl(o) : _bust(o, o.thumbUrl);

String _bust(Outfit o, String path) {
  final base = apiUrl(path);
  if (path.isEmpty) return base;
  final bust = '${o.id}-${o.modelTier}-${o.view}-${o.status}-${o.isMock ? 1 : 0}';
  final sep = base.contains('?') ? '&' : '?';
  return '$base${sep}b=$bust';
}

class OutfitCloth {
  final int id;
  final String name;
  final String brand;
  final String category;

  OutfitCloth(
      {required this.id,
      required this.name,
      required this.brand,
      this.category = ''});

  factory OutfitCloth.fromJson(Map<String, dynamic> json) => OutfitCloth(
        id: json['id'] as int,
        name: (json['name'] ?? '') as String,
        brand: (json['brand'] ?? '') as String,
        category: (json['category'] ?? '') as String,
      );
}

class Outfit {
  final int id;
  final int? modelId;
  final String? modelName;
  final List<int> clothIds;
  final List<OutfitCloth> cloths;
  final String prompt;
  final String generatedUrl;

  /// Server-rendered, grid-sized copy of [generatedUrl]. Empty when absent.
  final String thumbUrl;
  final String status; // 'done' | 'failed'
  final bool isMock;
  final String modelTier; // 'flex' | 'pro' | 'max'
  final String modelSlug;
  final String view; // 'front' | 'back'
  final int? linkedId; // paired opposite-view outfit, or null
  final bool isFavorite;
  final bool wornToday; // worn (via agenda) today
  final String? nextTier; // next cascade tier, or null if on the last tier
  final bool describeClothes; // items' brand/name/type added to the prompt
  final String imageMode; // 'collage' | 'separate'
  final List<int> renderClothIds; // subset actually drawn ([] = all)
  final bool isBlacklisted; // this cloth combo is banned from the generator
  final String error;
  final String? createdAt;
  // Human label of the generator algorithm, when the outfit came from one.
  final String? algoLabel;
  final String kind; // 'ai' (generated) | 'manual' (non-AI builder)
  // Manual builder layout (background + placed items), or null for AI outfits.
  final Map<String, dynamic>? layout;

  bool get isManual => kind == 'manual';

  Outfit({
    required this.id,
    required this.modelId,
    required this.modelName,
    required this.clothIds,
    required this.cloths,
    required this.prompt,
    required this.generatedUrl,
    this.thumbUrl = '',
    required this.status,
    required this.isMock,
    required this.modelTier,
    required this.modelSlug,
    required this.view,
    this.linkedId,
    required this.isFavorite,
    this.wornToday = false,
    required this.nextTier,
    this.describeClothes = false,
    this.imageMode = 'collage',
    this.renderClothIds = const [],
    this.isBlacklisted = false,
    required this.error,
    this.createdAt,
    this.algoLabel,
    this.kind = 'ai',
    this.layout,
  });

  factory Outfit.fromJson(Map<String, dynamic> json) {
    final clothsRaw = (json['cloths'] as List?) ?? [];
    return Outfit(
      id: json['id'] as int,
      modelId: json['model_id'] as int?,
      modelName: json['model_name'] as String?,
      clothIds: (json['cloth_ids'] as List?)?.map((e) => e as int).toList() ??
          const [],
      cloths: clothsRaw
          .map((e) => OutfitCloth.fromJson(e as Map<String, dynamic>))
          .toList(),
      prompt: (json['prompt'] ?? '') as String,
      generatedUrl: (json['generated_url'] ?? '') as String,
      thumbUrl: (json['thumb_url'] ?? '') as String,
      status: (json['status'] ?? 'done') as String,
      isMock: json['is_mock'] as bool? ?? false,
      modelTier: (json['model_tier'] ?? 'flex') as String,
      modelSlug: (json['model_slug'] ?? '') as String,
      view: (json['view'] ?? 'front') as String,
      linkedId: json['linked_id'] as int?,
      isFavorite: json['is_favorite'] as bool? ?? false,
      wornToday: json['worn_today'] as bool? ?? false,
      nextTier: json['next_tier'] as String?,
      describeClothes: json['describe_clothes'] as bool? ?? false,
      imageMode: (json['image_mode'] ?? 'collage') as String,
      renderClothIds: (json['render_cloth_ids'] as List?)
              ?.map((e) => e as int)
              .toList() ??
          const [],
      isBlacklisted: json['is_blacklisted'] as bool? ?? false,
      error: (json['error'] ?? '') as String,
      createdAt: json['created_at'] as String?,
      algoLabel: json['algo_label'] as String?,
      kind: (json['kind'] ?? 'ai') as String,
      layout: json['layout'] as Map<String, dynamic>?,
    );
  }

  /// A copy with a different linked opposite-view outfit (used when a back view
  /// is created for a front already shown in history).
  Outfit withLinkedId(int? linkedId) => Outfit(
        id: id,
        modelId: modelId,
        modelName: modelName,
        clothIds: clothIds,
        cloths: cloths,
        prompt: prompt,
        generatedUrl: generatedUrl,
        thumbUrl: thumbUrl,
        status: status,
        isMock: isMock,
        modelTier: modelTier,
        modelSlug: modelSlug,
        view: view,
        linkedId: linkedId,
        isFavorite: isFavorite,
        wornToday: wornToday,
        nextTier: nextTier,
        describeClothes: describeClothes,
        imageMode: imageMode,
        renderClothIds: renderClothIds,
        isBlacklisted: isBlacklisted,
        error: error,
        createdAt: createdAt,
        algoLabel: algoLabel,
        kind: kind,
        layout: layout,
      );

  String get tierLabel => const {
        'vto': 'Try-On',
        'flex': 'Flex',
        'pro': 'Pro',
        'max': 'Max',
        'klein': 'Flex', // legacy rows
        'flux': 'Pro', // legacy rows
      }[modelTier] ??
      modelTier;
}