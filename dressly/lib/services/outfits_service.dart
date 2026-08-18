import 'dart:convert';

import '../models/outfit.dart';
import '../config/api_config.dart';
import 'api_client.dart';

class AlgoMeta {
  final String id;
  final String label;
  final String needs; // 'none' | 'color' | 'brand'
  final String desc;
  AlgoMeta({required this.id, required this.label, required this.needs, required this.desc});
  factory AlgoMeta.fromJson(Map<String, dynamic> j) => AlgoMeta(
        id: j['id'] as String,
        label: j['label'] as String,
        needs: j['needs'] as String,
        desc: j['desc'] as String,
      );
}

class OutfitsService {
  OutfitsService(this._api);
  final ApiClient _api;

  /// Outfit history. Pass [limit]/[offset] to page it; omit [limit] for all.
  Future<List<Outfit>> list({
    String sort = 'newest', // newest | oldest | most_worn | least_worn
    bool favorite = false,
    String model = 'any', // any | with | none
    int? limit,
    int offset = 0,
  }) async {
    final qs = [
      'sort=$sort',
      if (favorite) 'favorite=true',
      if (model != 'any') 'model=$model',
      if (limit != null) 'limit=$limit',
      if (limit != null && offset > 0) 'offset=$offset',
    ].join('&');
    final data = await _api.get('/outfits?$qs') as List;
    return data.map((e) => Outfit.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Outfit> get(int id) async {
    final data = await _api.get('/outfits/$id');
    return Outfit.fromJson(data as Map<String, dynamic>);
  }

  /// Like [get], but if the outfit is still rendering (e.g. the linked view was
  /// just re-rendered after a cloth edit) waits for it to finish.
  Future<Outfit> getAwait(int id) async => _awaitCompletion(await get(id));

  /// Generation runs in the background server-side (status 'processing'). Poll
  /// GET /outfits/{id} with short requests until it's done/failed, instead of
  /// holding one long request open for the whole render.
  Future<Outfit> _awaitCompletion(Outfit o) async {
    if (o.status != 'processing') return o;
    for (var i = 0; i < 150; i++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      final next = await get(o.id);
      if (next.status != 'processing') return next;
    }
    return get(o.id); // give back the latest state on timeout
  }

  /// Make (or fetch) a public link to this outfit, and return its absolute URL.
  ///
  /// Idempotent server-side: pressing share twice hands back the same link
  /// rather than leaving a second one open.
  Future<({String url, String expiresAt})> share(int outfitId) async {
    final data = await _api.post('/outfits/$outfitId/share', const {})
        as Map<String, dynamic>;
    return (
      url: apiUrl((data['path'] ?? '') as String),
      expiresAt: (data['expires_at'] ?? '') as String,
    );
  }


  /// Stop every link to this outfit working.
  Future<void> unshare(int outfitId) async {
    await _api.delete('/outfits/$outfitId/share');
  }

  Future<List<Outfit>> favorites({
    String sort = 'newest',
    String model = 'any',
    int? limit,
    int offset = 0,
  }) async {
    final qs = [
      'sort=$sort',
      if (model != 'any') 'model=$model',
      if (limit != null) 'limit=$limit',
      if (limit != null && offset > 0) 'offset=$offset',
    ].join('&');
    final data = await _api.get('/outfits/favorites/list?$qs') as List;
    return data.map((e) => Outfit.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<List<AlgoMeta>> listAlgos() async {
    final data = await _api.get('/outfits/algos/list') as Map<String, dynamic>;
    final list = data['algos'] as List;
    return list.map((e) => AlgoMeta.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Outfit> generate({
    int? modelId,
    required List<int> clothIds,
    String prompt = '',
    String tier = 'flex',
    String view = 'front',
    bool randomModel = false,
    String randomModelGender = '',
    bool describeClothes = false,
    String imageMode = 'collage',
    List<int> renderClothIds = const [],
  }) async {
    final data = await _api.post('/outfits/generate', {
      'model_id': modelId,
      'random_model': randomModel,
      'random_model_gender': randomModelGender,
      'cloth_ids': clothIds,
      'prompt': prompt,
      'tier': tier,
      'view': view,
      'describe_clothes': describeClothes,
      'image_mode': imageMode,
      'render_cloth_ids': renderClothIds,
    });
    return _awaitCompletion(Outfit.fromJson(data as Map<String, dynamic>));
  }

  /// Swap one or more clothes in an existing outfit and re-render at the same
  /// tier. Used by the dialog's per-cloth remove + edit-clothes flow.
  Future<Outfit> replaceClothes(int outfitId, List<int> clothIds) async {
    final data = await _api.post('/outfits/$outfitId/replace-clothes', {
      'cloth_ids': clothIds,
    });
    return _awaitCompletion(Outfit.fromJson(data as Map<String, dynamic>));
  }

  /// Swap the person an outfit is rendered on (or drop the model when both
  /// args are null/false) and re-render with the same clothes.
  Future<Outfit> replaceModel(int outfitId,
      {int? modelId, bool randomModel = false}) async {
    final data = await _api.post('/outfits/$outfitId/replace-model', {
      if (modelId != null) 'model_id': modelId,
      'random_model': randomModel,
    });
    return _awaitCompletion(Outfit.fromJson(data as Map<String, dynamic>));
  }

  /// Generate the back view of an existing outfit (requires a model with a
  /// back photo). Returns the newly created outfit.
  Future<Outfit> generateBack(int outfitId) async {
    final data = await _api.post('/outfits/$outfitId/back', {});
    return _awaitCompletion(Outfit.fromJson(data as Map<String, dynamic>));
  }

  Future<Outfit> regenerate(int outfitId,
      {String? tier,
      bool? describeClothes,
      String? addDetail,
      String? imageMode,
      List<int>? renderClothIds}) async {
    final data = await _api.post('/outfits/$outfitId/regenerate', {
      if (tier != null) 'tier': tier,
      if (describeClothes != null) 'describe_clothes': describeClothes,
      if (addDetail != null && addDetail.isNotEmpty) 'add_detail': addDetail,
      if (imageMode != null) 'image_mode': imageMode,
      if (renderClothIds != null) 'render_cloth_ids': renderClothIds,
    });
    return _awaitCompletion(Outfit.fromJson(data as Map<String, dynamic>));
  }

  /// Toggle (or set) favorite. Returns the new favorite state.
  Future<bool> toggleFavorite(int outfitId, {bool? isFavorite}) async {
    final data = await _api.post('/outfits/$outfitId/favorite', {
      if (isFavorite != null) 'is_favorite': isFavorite,
    }) as Map<String, dynamic>;
    return data['is_favorite'] as bool? ?? false;
  }

  /// Ban (or un-ban) this outfit's cloth combination from the generator.
  /// Returns the new blacklisted state.
  Future<bool> setBlacklist(int outfitId, {bool? blacklisted}) async {
    final data = await _api.post('/outfits/$outfitId/blacklist', {
      if (blacklisted != null) 'blacklisted': blacklisted,
    }) as Map<String, dynamic>;
    return data['is_blacklisted'] as bool? ?? false;
  }

  Future<void> report(int outfitId, {String message = ''}) async {
    await _api.post('/outfits/$outfitId/report', {'message': message});
  }

  /// Record that the user wore this outfit (default: today). Stamps
  /// last_worn_at on all of the outfit's clothes.
  Future<void> wear(int outfitId, {String? day}) async {
    await _api.post('/outfits/$outfitId/wear', {if (day != null) 'day': day});
  }

  /// Days this outfit was worn + total and this-year counts.
  Future<OutfitWears> wears(int outfitId) async {
    final data = await _api.get('/outfits/$outfitId/wears');
    return OutfitWears.fromJson(data as Map<String, dynamic>);
  }

  Future<void> delete(int id) async {
    await _api.delete('/outfits/$id');
  }

  // --- manual (non-AI) outfit builder ---

  /// Persist a hand-composed outfit: [png] is the rasterised builder canvas,
  /// [layout] the JSON layout (background + placed items) so it can be
  /// re-opened for editing. No AI/model involved.
  Future<Outfit> saveManualOutfit({
    required List<int> png,
    required List<int> clothIds,
    required Map<String, dynamic> layout,
    int? outfitId, // when set, update the existing manual outfit instead
  }) async {
    final fields = {
      'cloth_ids': jsonEncode(clothIds),
      'layout': jsonEncode(layout),
    };
    final data = outfitId == null
        ? await _api.multipartBytes('POST', '/outfits/manual',
            fields: fields, fileField: 'image', bytes: png, filename: 'outfit.png')
        : await _api.multipartBytes('PUT', '/outfits/$outfitId/manual',
            fields: fields, fileField: 'image', bytes: png, filename: 'outfit.png');
    return Outfit.fromJson(data as Map<String, dynamic>);
  }

  // --- generator algorithms ---

  /// Run an algorithm and return its proposed selections (cloth items) WITHOUT
  /// generating any image. The user confirms in the UI, then each selection is
  /// rendered via [generate].
  Future<AlgoPreview> previewAlgo({
    required String algo,
    int minScore = 0,
    String color = '',
    String brand = '',
    String tag = '',
    int count = 1,
    int? modelId,
    String weather = 'any',
    List<String> categories = const [],
    List<int> lockedClothIds = const [],
    bool fillGaps = false,
  }) async {
    final data = await _api.post('/outfits/preview-algo', {
      'algo': algo,
      'min_score': minScore,
      'color': color,
      'brand': brand,
      'tag': tag,
      'count': count,
      'model_id': modelId,
      'weather': weather,
      'categories': categories,
      'locked_cloth_ids': lockedClothIds,
      'fill_gaps': fillGaps,
    }) as Map<String, dynamic>;
    final sels = (data['selections'] as List)
        .map((e) => (e as List)
            .map((c) => AlgoClothPick.fromJson(c as Map<String, dynamic>))
            .toList())
        .toList();
    return AlgoPreview(
      algo: data['algo'] as String,
      algoLabel: (data['algo_label'] ?? '') as String,
      selections: sels,
    );
  }
}

/// An outfit's wear history (days worn + counts).
class OutfitWears {
  final List<String> days;
  final int total;
  final int thisYear;
  OutfitWears({required this.days, required this.total, required this.thisYear});
  factory OutfitWears.fromJson(Map<String, dynamic> j) => OutfitWears(
        days: (j['days'] as List?)?.map((e) => e.toString()).toList() ?? const [],
        total: j['total'] as int? ?? 0,
        thisYear: j['this_year'] as int? ?? 0,
      );
}

/// A single cloth picked by an algorithm (preview, no image generated yet).
class AlgoClothPick {
  final int id;
  final String name;
  final String brand;
  final String category;
  final String role;
  final String thumbUrl;
  AlgoClothPick({
    required this.id,
    required this.name,
    required this.brand,
    required this.category,
    required this.role,
    required this.thumbUrl,
  });
  factory AlgoClothPick.fromJson(Map<String, dynamic> j) => AlgoClothPick(
        id: j['id'] as int,
        name: (j['name'] ?? '') as String,
        brand: (j['brand'] ?? '') as String,
        category: (j['category'] ?? '') as String,
        role: (j['role'] ?? '') as String,
        thumbUrl: (j['thumb_url'] ?? '') as String,
      );
}

/// Result of previewing an algorithm: the proposed selections (each a list of
/// cloth picks), ready for the user to confirm before any image is generated.
class AlgoPreview {
  final String algo;
  final String algoLabel;
  final List<List<AlgoClothPick>> selections;
  AlgoPreview({
    required this.algo,
    required this.algoLabel,
    required this.selections,
  });
}