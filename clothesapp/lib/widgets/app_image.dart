import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../config/api_config.dart';
import '../services/image_cache_config.dart';

/// A network image with disk+memory caching (via cached_network_image) and
/// optional decode-size capping. Grid thumbnails pass [memWidth] so a large
/// source photo is decoded down to roughly the display size — cutting memory
/// and scroll jank versus a raw `Image.network` that decodes at full
/// resolution. Pass an already-resolved absolute URL, or use [AppImage.path]
/// for a server-relative path that needs [imageUrl] applied.
class AppImage extends StatelessWidget {
  const AppImage({
    super.key,
    required this.url,
    this.fit = BoxFit.contain,
    this.memWidth,
    this.cacheKey,
  });

  /// Convenience for server-relative paths (`/images/...`) — resolves the base.
  factory AppImage.path(
    String? relativePath, {
    Key? key,
    BoxFit fit = BoxFit.contain,
    int? memWidth,
    String? cacheKey,
  }) =>
      AppImage(
        key: key,
        url: (relativePath == null || relativePath.isEmpty)
            ? ''
            : imageUrl(relativePath),
        fit: fit,
        memWidth: memWidth,
        cacheKey: cacheKey,
      );

  final String url;
  final BoxFit fit;

  /// Target decode width in logical px (multiplied by devicePixelRatio).
  final int? memWidth;

  /// Overrides the cache key (defaults to the URL). Useful when a URL is reused
  /// but the underlying image changes.
  final String? cacheKey;

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) {
      return const _Broken();
    }
    final dpr = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0;
    return CachedNetworkImage(
      imageUrl: url,
      // Without this the shared 200-file default manager is used, which is
      // smaller than a single wardrobe and evicts constantly.
      cacheManager: AppImageCache.instance,
      cacheKey: cacheKey,
      fit: fit,
      // Decode at ~display resolution (× devicePixelRatio for crispness on
      // retina), but capped so a huge phone photo doesn't blow up memory.
      memCacheWidth: memWidth == null ? null : _decodeWidth(memWidth!, dpr),
      fadeInDuration: const Duration(milliseconds: 150),
      placeholder: (_, __) => const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
      errorWidget: (_, __, ___) => const _Broken(),
    );
  }
}

/// Physical decode width: at least the logical size, scaled by dpr, capped.
int _decodeWidth(int logical, double dpr) {
  final t = (logical * dpr).round();
  if (t < logical) return logical;
  return t > 1600 ? 1600 : t;
}

/// Cached [ImageProvider] for widgets that take a provider rather than a child
/// — CircleAvatar, DecorationImage, precacheImage.
///
/// A bare `NetworkImage` keeps no disk copy, so an avatar built from one
/// re-downloads its picture on every rebuild. Pass a thumbnail URL: an avatar
/// is a few dozen pixels and has no use for the stored image.
ImageProvider appImageProvider(String url) =>
    CachedNetworkImageProvider(url, cacheManager: AppImageCache.instance);


class _Broken extends StatelessWidget {
  const _Broken();

  @override
  Widget build(BuildContext context) =>
      const Center(child: Icon(Icons.broken_image, color: Colors.white54));
}
