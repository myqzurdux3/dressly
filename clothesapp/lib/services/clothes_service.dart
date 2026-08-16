import 'dart:convert';
import 'dart:io';

import '../models/cloth.dart';
import '../models/dormant.dart';
import 'api_client.dart';

class ClothesService {
  ClothesService(this._api);
  final ApiClient _api;

  /// List clothes, optionally one page at a time.
  ///
  /// Omitting [limit] returns the whole wardrobe, which is what the picker and
  /// the generator need. The scrolling grids pass [limit]/[offset] so a large
  /// wardrobe never ships in a single response.
  Future<List<Cloth>> list({ClothFilter? filter, int? limit, int offset = 0}) async {
    final params = <String>[
      if (filter != null && filter.toQuery().isNotEmpty) filter.toQuery(),
      if (limit != null) 'limit=$limit',
      if (limit != null && offset > 0) 'offset=$offset',
    ];
    final path = '/clothes${params.isEmpty ? '' : '?${params.join('&')}'}';
    final data = await _api.get(path) as List;
    return data.map((e) => Cloth.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Cloth> get(int id) async {
    final data = await _api.get('/clothes/$id') as Map<String, dynamic>;
    return Cloth.fromJson(data);
  }

  Future<Cloth> create(ClothDraft draft) async {
    final data = await _api.postMultipart(
      '/clothes',
      fields: {
        'name': draft.name,
        'brand': draft.brand,
        'cut': draft.cut,
        'category': draft.category,
        'colors': jsonEncode(draft.colors.map((c) => c.toJson()).toList()),
        'tags': jsonEncode(draft.tags),
      },
      files: draft.images,
    );
    return Cloth.fromJson(data as Map<String, dynamic>);
  }

  /// Edit an existing cloth's metadata. Images are handled separately by
  /// [addImage] / [replaceImage] / [deleteImage] — the metadata PUT is
  /// multipart (Form fields) but carries no files.
  Future<Cloth> update(int id, ClothUpdate update) async {
    final fields = <String, String>{
      'name': update.name,
      'brand': update.brand,
      'cut': update.cut,
      'category': update.category,
      'colors': jsonEncode(update.colors.map((c) => c.toJson()).toList()),
      'tags': jsonEncode(update.tags),
    };
    final data = await _api.putMultipart(
      '/clothes/$id',
      fields: fields,
      files: const [],
    );
    return Cloth.fromJson(data as Map<String, dynamic>);
  }

  /// Append a new photo to an existing cloth.
  Future<Cloth> addImage(int clothId, File file, {String role = 'extra'}) async {
    final data = await _api.multipart(
      'POST',
      '/clothes/$clothId/images',
      fields: {'role': role},
      files: {'image': file},
    );
    return Cloth.fromJson(data as Map<String, dynamic>);
  }

  /// Replace the photo behind an existing image slot (re-runs bg removal).
  Future<Cloth> replaceImage(int clothId, int imageId, File file) async {
    final data = await _api.multipart(
      'PUT',
      '/clothes/$clothId/images/$imageId',
      files: {'image': file},
    );
    return Cloth.fromJson(data as Map<String, dynamic>);
  }

  /// Delete one photo from a cloth (server refuses to remove the last one).
  Future<Cloth> deleteImage(int clothId, int imageId) async {
    final data = await _api.delete('/clothes/$clothId/images/$imageId');
    return Cloth.fromJson(data as Map<String, dynamic>);
  }

  /// Rotate (clockwise degrees) and/or crop an image. `crop` is
  /// [left, top, right, bottom] each in 0..1. Applies to original + cut-out.
  Future<Cloth> transformImage(int clothId, int imageId,
      {int rotate = 0, List<double>? crop}) async {
    final body = <String, dynamic>{'rotate': rotate};
    if (crop != null) {
      body['crop'] = {
        'left': crop[0],
        'top': crop[1],
        'right': crop[2],
        'bottom': crop[3],
      };
    }
    final data = await _api.post(
      '/clothes/$clothId/images/$imageId/transform',
      body,
    );
    return Cloth.fromJson(data as Map<String, dynamic>);
  }

  /// Record that the user wore this cloth (default: today).
  Future<void> wear(int id, {String? day}) async {
    await _api.post('/clothes/$id/wear', {if (day != null) 'day': day});
  }

  /// Clothes untouched for [months] or more, longest-forgotten first, with the
  /// wardrobe totals for the header.
  Future<DormantReport> dormant(
      {int months = 6, int? limit, int offset = 0}) async {
    final params = <String>[
      'months=$months',
      if (limit != null) 'limit=$limit',
      if (limit != null && offset > 0) 'offset=$offset',
    ];
    final data = await _api.get('/clothes/dormant?${params.join('&')}');
    return DormantReport.fromJson(data as Map<String, dynamic>);
  }

  Future<void> delete(int id) async {
    await _api.delete('/clothes/$id');
  }

  /// Set the user's 0–5 rating for a cloth.
  Future<void> setScore(int id, int score) async {
    await _api.patch('/clothes/$id/score', {'score': score});
  }

  /// Start an enhancement for one image. `mode` is 'auto' (free, deterministic)
  /// or 'ai' (FLUX de-wrinkle/flatten). Returns the cloth with the image marked
  /// 'processing'; poll with [pollEnhance].
  ///
  /// [describe] decides whether what the owner typed about the garment — name,
  /// brand, cut, colours, tags — goes into the AI prompt. Omitting it keeps
  /// whatever the image was last set to, which is what makes a retry repeat the
  /// same job instead of reverting to the default.
  Future<Cloth> enhanceImage(int clothId, int imageId, String mode,
      {String tier = 'flex', bool? describe}) async {
    final data = await _api.post(
      '/clothes/$clothId/images/$imageId/enhance',
      {'mode': mode, 'tier': tier, if (describe != null) 'describe': describe},
    );
    return Cloth.fromJson(data as Map<String, dynamic>);
  }

  /// Save the "describe this garment in the AI prompt" choice WITHOUT starting
  /// a run — the user is setting up the next enhancement, not asking for one.
  Future<Cloth> setEnhanceDescribe(
      int clothId, int imageId, bool describe) async {
    final data = await _api.patch(
      '/clothes/$clothId/images/$imageId/enhance-describe',
      {'describe': describe},
    );
    return Cloth.fromJson(data as Map<String, dynamic>);
  }

  /// Re-run background removal on the current (possibly cropped/rotated) photo,
  /// at a chosen tolerance: 'low' (keep more) / 'medium' / 'high' (remove more).
  Future<Cloth> redoBackground(int clothId, int imageId,
      {String tolerance = 'medium'}) async {
    final data = await _api.post(
      '/clothes/$clothId/images/$imageId/redo-bg',
      {'tolerance': tolerance},
    );
    return Cloth.fromJson(data as Map<String, dynamic>);
  }

  /// Poll the cloth until the given image's enhancement is no longer running.
  Future<Cloth> pollEnhance(int clothId, int imageId,
      {int maxTries = 150}) async {
    for (var i = 0; i < maxTries; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      final c = await get(clothId);
      var stillRunning = false;
      for (final x in c.images) {
        if (x.id == imageId) {
          stillRunning = x.enhanceStatus == 'processing';
          break;
        }
      }
      if (!stillRunning) return c;
    }
    return get(clothId);
  }

  /// Poll a freshly added garment until every photo has been cut out.
  ///
  /// Adding a garment now answers before the cut-outs exist, so the app shows
  /// the originals with a "cutting out" badge and calls this to learn when the
  /// real thing is ready. Gives up quietly after [maxTries] rather than
  /// hammering: the next screen refresh will pick it up anyway.
  Future<Cloth> pollCutouts(int clothId, {int maxTries = 60}) async {
    for (var i = 0; i < maxTries; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      final c = await get(clothId);
      if (!c.images.any((x) => x.cutoutStatus == 'processing')) return c;
    }
    return get(clothId);
  }

  Future<Cloth> acceptEnhance(int clothId, int imageId) async {
    final data = await _api.post(
      '/clothes/$clothId/images/$imageId/enhance/accept',
      const <String, dynamic>{},
    );
    return Cloth.fromJson(data as Map<String, dynamic>);
  }

  Future<Cloth> rejectEnhance(int clothId, int imageId) async {
    final data = await _api.post(
      '/clothes/$clothId/images/$imageId/enhance/reject',
      const <String, dynamic>{},
    );
    return Cloth.fromJson(data as Map<String, dynamic>);
  }

  Future<void> acceptImage(int clothId, int imageId) async {
    await _api.post(
      '/clothes/$clothId/images/$imageId/accept',
      const <String, dynamic>{},
    );
  }

  Future<void> rejectImage(int clothId, int imageId) async {
    await _api.post(
      '/clothes/$clothId/images/$imageId/reject',
      const <String, dynamic>{},
    );
  }

  /// Favorite/unfavorite a cloth. Returns the new state.
  Future<bool> toggleFavorite(int id, {bool? isFavorite}) async {
    final data = await _api.post('/clothes/$id/favorite', {
      if (isFavorite != null) 'is_favorite': isFavorite,
    }) as Map<String, dynamic>;
    return data['is_favorite'] as bool? ?? false;
  }

  /// Exclude/include a cloth in the generation algorithms. Returns the new state.
  Future<bool> setExcludeFromAlgo(int id, {bool? exclude}) async {
    final data = await _api.post('/clothes/$id/exclude-algo', {
      if (exclude != null) 'exclude': exclude,
    }) as Map<String, dynamic>;
    return data['exclude_from_algo'] as bool? ?? false;
  }

  Future<ClothWears> wears(int id) async {
    final data = await _api.get('/clothes/$id/wears');
    return ClothWears.fromJson(data as Map<String, dynamic>);
  }

  /// Auto-detect dominant colors from the cloth's cut-out (suggestions only).
  Future<List<ClothColor>> detectColors(int id) async {
    final data = await _api.post('/clothes/$id/detect-colors', {})
        as Map<String, dynamic>;
    final list = (data['colors'] as List?) ?? const [];
    return list
        .map((e) => ClothColor.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Warn admins about a cut-out problem (without changing the choice).
  Future<void> reportImage(int clothId, int imageId, {String message = ''}) async {
    await _api.post('/clothes/$clothId/images/$imageId/report',
        {'message': message});
  }

  Future<List<String>> autocompleteBrands() async {
    final data = await _api.get('/autocomplete/brands');
    return (data as List).map((e) => e.toString()).toList();
  }

  Future<List<String>> autocompleteTags() async {
    final data = await _api.get('/autocomplete/tags');
    return (data as List).map((e) => e.toString()).toList();
  }
}

class ClothFilter {
  ClothFilter({
    this.search,
    this.brand,
    this.color,
    this.cut,
    this.category,
    this.tag,
    this.sort,
    this.minScore,
    this.favorite = false,
  });

  final String? search;
  final String? brand;
  final String? color;
  final String? cut;
  final String? category;
  final String? tag;
  final String? sort; // 'newest' | 'name' | 'brand' | 'score' | 'score_asc'
  final int? minScore; // null = no rating filter; 1..5 = only clothes rated >=
  final bool favorite; // only favorite clothes

  bool get isEmpty =>
      (search?.isEmpty ?? true) &&
      (brand?.isEmpty ?? true) &&
      (color?.isEmpty ?? true) &&
      (cut?.isEmpty ?? true) &&
      (category?.isEmpty ?? true) &&
      (tag?.isEmpty ?? true) &&
      !favorite &&
      (minScore == null || minScore == 0);

  String toQuery() {
    final params = <String>[];
    void add(String key, String? val) {
      if (val != null && val.isNotEmpty) params.add('$key=${Uri.encodeQueryComponent(val)}');
    }
    add('search', search);
    add('brand', brand);
    add('color', color);
    add('cut', cut);
    add('category', category);
    add('tag', tag);
    add('sort', sort);
    if (minScore != null && minScore! > 0) params.add('min_score=$minScore');
    if (favorite) params.add('favorite=true');
    return params.join('&');
  }

  ClothFilter copyWith({
    String? search,
    String? brand,
    String? color,
    String? cut,
    String? category,
    String? tag,
    String? sort,
    int? minScore,
    bool? favorite,
    bool clearMinScore = false,
    bool clearSearch = false,
  }) =>
      ClothFilter(
        search: clearSearch ? null : (search ?? this.search),
        brand: brand ?? this.brand,
        color: color ?? this.color,
        cut: cut ?? this.cut,
        category: category ?? this.category,
        tag: tag ?? this.tag,
        sort: sort ?? this.sort,
        minScore: clearMinScore ? null : (minScore ?? this.minScore),
        favorite: favorite ?? this.favorite,
      );
}

/// A cloth's wear history summary.
class ClothWears {
  final List<String> days;
  final int total;
  final int thisYear;
  ClothWears({required this.days, required this.total, required this.thisYear});
  factory ClothWears.fromJson(Map<String, dynamic> j) => ClothWears(
        days: (j['days'] as List?)?.map((e) => e.toString()).toList() ?? const [],
        total: j['total'] as int? ?? 0,
        thisYear: j['this_year'] as int? ?? 0,
      );
}

class ClothDraft {
  ClothDraft({
    required this.name,
    required this.brand,
    required this.cut,
    required this.category,
    required this.colors,
    required this.tags,
    required this.images,
  });

  final String name;
  final String brand;
  final String cut;
  final String category;
  final List<ClothColor> colors;
  final List<String> tags;
  final List<File> images; // ordered: front, back, then extras
}

/// Used by the edit form (PUT /clothes/{id}) for metadata only. Photos are
/// added/replaced/removed through the dedicated image endpoints. `score` is
/// intentionally omitted — use [ClothesService.setScore] directly.
class ClothUpdate {
  ClothUpdate({
    required this.name,
    required this.brand,
    required this.cut,
    required this.category,
    required this.colors,
    required this.tags,
  });

  final String name;
  final String brand;
  final String cut;
  final String category;
  final List<ClothColor> colors;
  final List<String> tags;
}