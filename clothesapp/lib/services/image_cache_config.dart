import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import 'pinned_http.dart';
import 'timeout_file_service.dart';

/// Disk cache for wardrobe images.
///
/// `cached_network_image` otherwise uses the shared default manager, which
/// keeps **200** files. A wardrobe of ~110 clothes already produces more than
/// that once each card's front and back thumbnails are counted, before any
/// outfit render — so the cache thrashed: entries were evicted almost as fast
/// as they were written, and every visit to the wardrobe re-downloaded
/// everything over a link with a ~250 ms round trip.
///
/// Sized for a large personal wardrobe rather than a browsing session.
class AppImageCache {
  /// Separate from the default manager's key so raising the limit does not
  /// require invalidating anything already stored.
  static const String key = 'dresslyImageCache';

  /// Roughly: every cloth's thumbnails and full images, plus outfit renders,
  /// with room to grow. Thumbnails are ~26 KB, so even 2000 of them is modest.
  static const int maxObjects = 2000;

  /// Images are immutable at a given URL (the server appends `?v=<mtime>`), so a
  /// long period costs nothing: a changed photo arrives under a new URL.
  static const Duration stalePeriod = Duration(days: 60);

  static final CacheManager instance = CacheManager(
    Config(
      key,
      stalePeriod: stalePeriod,
      maxNrOfCacheObjects: maxObjects,
      // Two reasons for a custom file service.
      //
      // The client is shared with the API calls, so every image download reuses
      // one connection pool: measured against the deployed server, eight
      // sequential requests cost 140 ms each over a kept-alive connection
      // against 670 ms each when every one reconnects.
      //
      // And it has a deadline. The cache manager runs ten downloads at a time
      // and frees a slot in a `finally` — which a request that never answers
      // never reaches, so it holds that slot forever. Ten such requests and
      // images stop loading permanently.
      fileService: TimeoutFileService(httpClient: PinnedHttp.shared),
    ),
  );

  /// Raise the in-memory decoded-image budget too.
  ///
  /// The disk cache avoids the network; this avoids re-decoding. Flutter
  /// defaults to 100 MB, which a grid of large cut-outs can churn through.
  static void configureMemoryCache() {
    PaintingBinding.instance.imageCache
      ..maximumSizeBytes = 200 << 20 // 200 MB
      ..maximumSize = 2000; // entries
  }
}
