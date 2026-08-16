class ModelImage {
  final int id;
  final String role; // 'front' | 'back' | 'extra'
  final String bgAccepted; // 'pending' | 'accepted' | 'rejected'
  final String originalUrl;
  final String cutoutUrl;

  /// Server-rendered screen-sized copies; empty falls back to the stored file.
  final String thumbUrl;
  final String previewUrl;

  ModelImage({
    required this.id,
    required this.role,
    required this.bgAccepted,
    required this.originalUrl,
    required this.cutoutUrl,
    this.thumbUrl = '',
    this.previewUrl = '',
  });

  /// Rejecting bg-removal falls back to the original photo, evaluated on the
  /// client so we never serve stale cutout pixels regardless of server aliasing.
  String? get displayUrl {
    if (bgAccepted == 'rejected') return originalUrl;
    return cutoutUrl.isNotEmpty ? cutoutUrl : originalUrl;
  }

  /// What a screen should render: the stored file is far larger than any phone
  /// can show.
  String? get displayPreviewUrl =>
      previewUrl.isNotEmpty ? previewUrl : displayUrl;

  String? get thumbnailUrl => thumbUrl.isNotEmpty ? thumbUrl : displayUrl;

  factory ModelImage.fromJson(Map<String, dynamic> json) => ModelImage(
        id: json['id'] as int,
        role: (json['role'] ?? 'front') as String,
        bgAccepted: (json['bg_accepted'] ?? 'pending') as String,
        originalUrl: (json['original_url'] ?? '') as String,
        cutoutUrl: (json['cutout_url'] ?? '') as String,
        thumbUrl: (json['thumb_url'] ?? '') as String,
        previewUrl: (json['preview_url'] ?? '') as String,
      );
}

class ModelEntity {
  final int id;
  final String name;
  final String gender; // '' unknown | 'male' | 'female'
  final List<ModelImage> images;
  final String? createdAt;

  ModelEntity({
    required this.id,
    required this.name,
    this.gender = '',
    required this.images,
    this.createdAt,
  });

  String? get displayImageUrl {
    if (images.isEmpty) return null;
    return images.first.displayUrl;
  }

  /// Grid-sized. A card or a chip has no use for the stored file.
  String? get thumbImageUrl {
    if (images.isEmpty) return null;
    return images.first.thumbnailUrl;
  }

  factory ModelEntity.fromJson(Map<String, dynamic> json) => ModelEntity(
        id: json['id'] as int,
        name: (json['name'] ?? '') as String,
        gender: (json['gender'] ?? '') as String,
        images: (json['images'] as List?)
                ?.map((e) => ModelImage.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        createdAt: json['created_at'] as String?,
      );
}