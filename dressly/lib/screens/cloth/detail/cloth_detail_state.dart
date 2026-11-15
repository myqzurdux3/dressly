import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/cloth.dart';
import '../../../services/clothes_service.dart';
import '../../../state/providers.dart';

/// One garment, as the detail screen shows it.
///
/// Every action updates [state] in place. A refresh keeps the garment on
/// screen while it runs — reported: "à chaque fois que je rogne un habit la
/// page se reload", when every action blanked the page to a spinner. A failed
/// refresh keeps what is shown; only a failed first load is an error.
///
/// Actions throw on failure; the screen turns that into a message.
class ClothDetail extends AsyncNotifier<Cloth> {
  ClothDetail(this.id);

  final int id;

  ClothesService get _svc => ref.read(clothesServiceProvider);

  /// True while a poll for pending cut-outs runs, so only one does.
  bool _watchingCutouts = false;

  @override
  Future<Cloth> build() async {
    final c = await ref.watch(clothesServiceProvider).get(id);
    _watchCutouts(c);
    return c;
  }

  /// Shows [c] — a garment the server just returned — without refetching.
  void apply(Cloth c) {
    state = AsyncData(c);
    _watchCutouts(c);
  }

  /// Refetches; on failure the garment already shown stays.
  Future<void> reload() async {
    try {
      apply(await _svc.get(id));
    } catch (e, st) {
      if (!state.hasValue) state = AsyncError(e, st);
    }
  }

  /// A garment added a moment ago still has its cut-outs being made. Wait for
  /// them and show the result, so the badge and the picture update on their
  /// own. A failed poll says nothing: the photo shown is right, just not cut
  /// out yet, and any later refresh picks it up.
  void _watchCutouts(Cloth c) {
    if (_watchingCutouts) return;
    if (!c.images.any((x) => x.cutoutStatus == 'processing')) return;
    _watchingCutouts = true;
    final svc = _svc;
    unawaited(() async {
      try {
        final fresh = await svc.pollCutouts(id);
        if (ref.mounted) state = AsyncData(fresh);
      } catch (_) {
      } finally {
        _watchingCutouts = false;
      }
    }());
  }

  Cloth get _current => state.requireValue;

  Future<void> toggleFavorite() async {
    await _svc.toggleFavorite(id, isFavorite: !_current.isFavorite);
    await reload();
  }

  Future<void> setExcludeFromAlgo(bool exclude) async {
    await _svc.setExcludeFromAlgo(id, exclude: exclude);
    await reload();
  }

  Future<void> setScore(int score) async {
    await _svc.setScore(id, score);
    await reload();
  }

  Future<void> wearToday() async {
    await _svc.wear(id);
    await reload();
  }

  Future<ClothWears> wears() => _svc.wears(id);

  Future<void> delete() => _svc.delete(id);

  /// Keep the cut-out ([accept]) or the original photo. Final either way.
  Future<void> decideCutout(ClothImage img, {required bool accept}) async {
    if (accept) {
      await _svc.acceptImage(id, img.id);
    } else {
      await _svc.rejectImage(id, img.id);
    }
    await reload();
  }

  /// Re-runs the background removal at another strength.
  Future<void> setTolerance(ClothImage img, String level) async {
    await _svc.redoBackground(id, img.id, tolerance: level);
    await reload();
  }

  /// Saves whether the AI prompt describes the garment. Shown at once — a
  /// checkbox must not wait on a round trip — and saved behind it.
  Future<void> setEnhanceDescribe(ClothImage img, bool describe) async {
    final c = _current;
    apply(
      c.copyWith(
        images: [
          for (final im in c.images)
            if (im.id == img.id) im.copyWith(enhanceDescribe: describe) else im,
        ],
      ),
    );
    await _svc.setEnhanceDescribe(id, img.id, describe);
  }

  /// Starts an enhancement, shows it running, waits for it, shows the result.
  Future<void> enhance(
    ClothImage img,
    String mode, {
    String tier = 'flex',
  }) async {
    await _svc.enhanceImage(id, img.id, mode, tier: tier);
    if (!ref.mounted) return;
    await reload(); // 'processing'
    await _svc.pollEnhance(id, img.id);
    if (!ref.mounted) return;
    await reload(); // 'ready' or 'failed'
  }

  Future<void> acceptEnhance(ClothImage img) async {
    await _svc.acceptEnhance(id, img.id);
    await reload();
  }

  Future<void> rejectEnhance(ClothImage img) async {
    await _svc.rejectEnhance(id, img.id);
    await reload();
  }

  Future<void> reportImage(ClothImage img, String message) =>
      _svc.reportImage(id, img.id, message: message);
}

final clothDetailProvider = AsyncNotifierProvider.autoDispose
    .family<ClothDetail, Cloth, int>(
      ClothDetail.new,
      dependencies: [clothesServiceProvider],
    );
