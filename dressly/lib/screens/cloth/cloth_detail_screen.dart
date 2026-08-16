import 'package:flutter/material.dart';

import '../../app.dart';
import '../../config/api_config.dart';
import '../../l10n/app_text.dart';
import '../../widgets/app_image.dart';
import '../../models/cloth.dart';
import '../../services/clothes_service.dart';
import '../../widgets/image_review.dart';
import '../../widgets/star_rating.dart';
import 'add_cloth_screen.dart';  // ClothFormScreen + AddClothScreen typedef
import 'photo_edit_screen.dart';

/// Full view of one cloth: the structured info (category, cut, colors, tags)
/// followed by a scrollable list of per-image cards. Each card lets the user
/// keep the automatic cutout OR fall back to the original photo — this is the
/// background-removal review. Long-press / overflow menu offers delete.
class ClothDetailScreen extends StatefulWidget {
  const ClothDetailScreen({super.key, required this.clothId});

  final int clothId;

  @override
  State<ClothDetailScreen> createState() => _ClothDetailScreenState();
}

class _ClothDetailScreenState extends State<ClothDetailScreen> {
  Future<Cloth>? _future;
  // Latest resolved cloth — used by the edit button to push the form
  // pre-populated with the current values without waiting on the future.
  Cloth? _last;
  // Image ids whose accept/reject HTTP call is still in flight. Guards against
  // rapid taps queuing parallel/conflicting requests that left the UI blank.
  final Set<int> _busy = {};

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    final svc = clothesServiceOf(context);
    // Block body (not an arrow) so the closure is a true VoidCallback — an
    // arrow returning the Future triggers Flutter's "setState returned a
    // Future" assertion.
    final future = svc.get(widget.clothId).then((c) {
      _last = c;
      _watchCutouts(c);
      return c;
    });
    setState(() {
      _future = future;
    });
  }

  /// Take a cloth the server just handed back and show it, without asking for
  /// it again.
  ///
  /// Reported: "à chaque fois que je rogne un habit la page se reload". It did
  /// — every action replaced the future with a fresh GET, and the FutureBuilder
  /// blanked the whole screen to a spinner while it ran. The crop endpoint
  /// already returns the updated cloth, so there is nothing to fetch: the image
  /// URLs carry a new cache-buster and the picture changes on the spot.
  void _applyCloth(Cloth c) {
    _last = c;
    setState(() {
      _future = Future.value(c);
    });
    _watchCutouts(c);
  }

  /// True while a poll for pending cut-outs is already running, so opening the
  /// screen twice does not start two.
  bool _watchingCutouts = false;

  /// A garment added a moment ago still has its cut-outs being made. Wait for
  /// them and refresh once, so the badge and the picture update on their own.
  void _watchCutouts(Cloth c) {
    if (_watchingCutouts) return;
    if (!c.images.any((x) => x.cutoutStatus == 'processing')) return;
    _watchingCutouts = true;
    final svc = clothesServiceOf(context);
    () async {
      try {
        final fresh = await svc.pollCutouts(widget.clothId);
        if (!mounted) return;
        _last = fresh;
        setState(() {
          _future = Future.value(fresh);
        });
      } catch (_) {
        // Nothing to tell the user: the photo on screen is the right photo, it
        // is just not cut out yet, and any later refresh will pick it up.
      } finally {
        _watchingCutouts = false;
      }
    }();
  }

  Future<void> _edit() async {
    // Push the edit form with the current cloth so fields are pre-filled. The
    // form pops with `true` when it saved, then we refetch.
    await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => ClothFormScreen(initial: _last),
      ),
    );
    // Always refetch on return: the edit form saves image changes live, so the
    // detail view can be stale even when the user backs out without pressing
    // "Save changes".
    if (mounted) _reload();
  }

  Future<void> _delete() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(tr(context, 'detail.deleteTitle')),
        content: Text(tr(context, 'detail.deleteConfirm')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(tr(context, 'common.cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr(context, 'common.delete'))),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    try {
      final svc = clothesServiceOf(context);
      await svc.delete(widget.clothId);
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('${tr(context, 'detail.deleteFailed')}: $e')));
      }
    }
  }

  Future<void> _act(ClothImage img, {required bool accept}) async {
    if (_busy.contains(img.id)) return; // ignore double-taps
    setState(() => _busy.add(img.id));
    try {
      final svc = clothesServiceOf(context);
      if (accept) {
        await svc.acceptImage(widget.clothId, img.id);
        _toastKey('detail.cutoutKept');
      } else {
        await svc.rejectImage(widget.clothId, img.id);
        _toastKey('detail.keepingOriginal');
      }
      _reload();
    } catch (e) {
      _toastKey('detail.actionFailed', e);
    } finally {
      if (mounted) setState(() => _busy.remove(img.id));
    }
  }

  Future<void> _wearToday() async {
    try {
      await clothesServiceOf(context).wear(widget.clothId);
      _toastKey('detail.markedWorn');
      _reload();
    } catch (e) {
      _toastKey('detail.failed', e);
    }
  }

  Future<void> _setTolerance(ClothImage img, String level) async {
    if (_busy.contains(img.id) || level == img.bgTolerance) return;
    setState(() => _busy.add(img.id));
    try {
      await clothesServiceOf(context).redoBackground(widget.clothId, img.id,
          tolerance: level);
      _toastKey('detail.bgRedone');
      _reload();
    } catch (e) {
      _toastKey('detail.failed', e);
    } finally {
      if (mounted) setState(() => _busy.remove(img.id));
    }
  }

  Future<void> _toggleFavorite() async {
    final c = _last;
    if (c == null) return;
    try {
      await clothesServiceOf(context)
          .toggleFavorite(c.id, isFavorite: !c.isFavorite);
      _reload();
    } catch (e) {
      _toastKey('detail.failed', e);
    }
  }

  Future<void> _toggleExcludeAlgo(bool value) async {
    final c = _last;
    if (c == null) return;
    try {
      await clothesServiceOf(context).setExcludeFromAlgo(c.id, exclude: value);
      _reload();
    } catch (e) {
      _toastKey('detail.failed', e);
    }
  }

  Future<void> _reportImage(ClothImage img) async {
    final svc = clothesServiceOf(context);
    final messenger = ScaffoldMessenger.of(context);
    final reportedMsg = tr(context, 'detail.reported');
    final reportFailedMsg = tr(context, 'detail.reportFailed');
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(tr(context, 'detail.reportTitle')),
        content: TextField(
          controller: ctrl,
          decoration: InputDecoration(
            hintText: tr(context, 'detail.reportHint'),
            border: const OutlineInputBorder(),
          ),
          maxLines: 2,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(tr(context, 'common.cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr(context, 'detail.sendToAdmins'))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await svc.reportImage(widget.clothId, img.id, message: ctrl.text.trim());
      messenger.showSnackBar(SnackBar(content: Text(reportedMsg)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$reportFailedMsg: $e')));
    }
  }

  Future<void> _showWearHistory(Cloth cloth) async {
    final svc = clothesServiceOf(context);
    ClothWears? w;
    try {
      w = await svc.wears(cloth.id);
    } catch (_) {}
    if (!mounted || w == null) return;
    final wears = w;
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${tr(context, 'detail.worn')} ${wears.total} '
                  '${trPlural(context, 'detail.day', wears.total)} '
                  '· ${wears.thisYear} ${tr(context, 'detail.thisYear')}',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              if (wears.days.isEmpty)
                Text(tr(context, 'detail.notWornYet'), style: const TextStyle(color: Colors.grey))
              else
                Flexible(
                  child: SingleChildScrollView(
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: wears.days
                          .map((d) => Chip(label: Text(d)))
                          .toList(),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _cropRotate(ClothImage img) async {
    final updated = await Navigator.push<Cloth>(
      context,
      MaterialPageRoute(
        builder: (_) => PhotoEditScreen(clothId: widget.clothId, image: img),
      ),
    );
    if (updated != null && mounted) _applyCloth(updated);
  }

  /// Save the describe choice without starting a run: the user is setting up
  /// the next enhancement, not asking for one.
  Future<void> _setEnhanceDescribe(ClothImage img, bool describe) async {
    final svc = clothesServiceOf(context);
    // Reflected immediately — the checkbox must not wait on a round trip.
    _applyCloth(_lastWith(img.id, describe));
    try {
      await svc.setEnhanceDescribe(widget.clothId, img.id, describe);
    } catch (e) {
      if (mounted) _toastKey('detail.enhanceFailed', e);
    }
  }

  /// The current cloth with one image's describe flag flipped.
  Cloth _lastWith(int imageId, bool describe) {
    final cloth = _last!;
    return cloth.copyWith(images: [
      for (final im in cloth.images)
        if (im.id == imageId) im.copyWith(enhanceDescribe: describe) else im,
    ]);
  }

  Future<void> _enhance(ClothImage img, String mode, {String tier = 'flex'}) async {
    final svc = clothesServiceOf(context);
    try {
      await svc.enhanceImage(widget.clothId, img.id, mode, tier: tier);
      if (!mounted) return;
      _reload(); // reflect 'processing'
      await svc.pollEnhance(widget.clothId, img.id);
      if (!mounted) return;
      _reload(); // reflect 'ready' / 'failed'
    } catch (e) {
      _toastKey('detail.enhanceFailed', e);
    }
  }

  Future<void> _acceptEnhance(ClothImage img) async {
    final svc = clothesServiceOf(context);
    try {
      await svc.acceptEnhance(widget.clothId, img.id);
      if (!mounted) return;
      _reload();
      _toastKey('detail.enhanceApplied');
    } catch (e) {
      _toastKey('detail.failed', e);
    }
  }

  Future<void> _rejectEnhance(ClothImage img) async {
    final svc = clothesServiceOf(context);
    try {
      await svc.rejectEnhance(widget.clothId, img.id);
      if (!mounted) return;
      _reload();
    } catch (e) {
      _toastKey('detail.failed', e);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Translated toast by key (+ optional error), keeping `context` out of async
  /// call sites (no use-after-await lint).
  void _toastKey(String key, [Object? err]) {
    if (!mounted) return;
    final msg = tr(context, key);
    _toast(err == null ? msg : '$msg: $err');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'detail.title')),
        actions: [
          if (_last != null)
            IconButton(
              icon: Icon(
                  _last!.isFavorite ? Icons.favorite : Icons.favorite_border,
                  color: _last!.isFavorite ? Colors.redAccent : null),
              tooltip: tr(context, 'detail.favorite'),
              onPressed: _toggleFavorite,
            ),
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: tr(context, 'form.editTitle'),
            onPressed: _edit,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: tr(context, 'common.delete'),
            onPressed: _delete,
          ),
        ],
      ),
      body: FutureBuilder<Cloth>(
        future: _future,
        builder: (context, snap) {
          // Only the very first load gets a spinner. Afterwards the last known
          // cloth stays on screen while a refresh runs, so an accept, a reject
          // or a redo does not blank the page either.
          final waiting = snap.connectionState == ConnectionState.waiting;
          if (waiting && _last == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError && _last == null) {
            return Center(child: Text('${tr(context, 'detail.error')}: ${snap.error}'));
          }
          final cloth = snap.data ?? _last!;
          if (cloth.images.isEmpty) {
            return Center(child: Text(tr(context, 'detail.noImages')));
          }
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Info header.
                Text(cloth.name,
                    style: const TextStyle(
                        fontSize: 22, fontWeight: FontWeight.bold)),
                if (cloth.brand.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(cloth.brand,
                        style: const TextStyle(
                            fontSize: 15, color: Colors.white70)),
                  ),
                const SizedBox(height: 12),
                // User rating — used by the generator's min-score filter.
                Row(children: [
                  Text(tr(context, 'detail.rating'),
                      style: const
                          TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                  const SizedBox(width: 12),
                  StarRating(
                    score: cloth.score,
                    onChanged: (v) async {
                      final svc = clothesServiceOf(context);
                      final messenger = ScaffoldMessenger.of(context);
                      final failMsg = tr(context, 'detail.ratingFailed');
                      try {
                        await svc.setScore(cloth.id, v);
                        _reload();
                      } catch (e) {
                        messenger.showSnackBar(
                            SnackBar(content: Text('$failMsg: $e')));
                      }
                    },
                  ),
                ]),
                const SizedBox(height: 4),
                // Exclude from generation algorithms (still usable by hand).
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: cloth.excludeFromAlgo,
                  onChanged: _toggleExcludeAlgo,
                  secondary: const Icon(Icons.block, size: 20),
                  title: Text(tr(context, 'detail.excludeAlgo')),
                  subtitle: Text(tr(context, 'detail.excludeAlgoHint'),
                      style: const TextStyle(fontSize: 12)),
                ),
                const SizedBox(height: 12),
                // Last worn — tap to see all days worn + count this year.
                Row(children: [
                  const Icon(Icons.history, size: 18, color: Colors.white54),
                  const SizedBox(width: 6),
                  Expanded(
                    child: InkWell(
                      onTap: () => _showWearHistory(cloth),
                      child: Text(
                        cloth.lastWornAt == null
                            ? tr(context, 'detail.neverWorn')
                            : '${tr(context, 'detail.lastWorn')} ${cloth.lastWornAt} · ${tr(context, 'detail.tapForHistory')}',
                        style: const TextStyle(
                            color: Colors.white70,
                            decoration: TextDecoration.underline),
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _wearToday,
                    icon: const Icon(Icons.checkroom, size: 18),
                    label: Text(tr(context, 'detail.wornToday')),
                  ),
                ]),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    if (cloth.category.isNotEmpty)
                      _Pill(
                          label: tr(context, 'detail.categoryLabel'),
                          value: categoryName(context, cloth.category)),
                    if (categoryHasCut(cloth.category) && cloth.cut.isNotEmpty)
                      _Pill(label: tr(context, 'detail.cutLabel'), value: cutLabel(context, cloth.cut)),
                  ],
                ),
                if (cloth.colors.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(tr(context, 'detail.colors'),
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: cloth.colors
                        .map((c) => Chip(
                              label: Text(
                                  '${colorName(context, c.color)} · ${dominanceLabel(context, c.dominance)}'),
                            ))
                        .toList(),
                  ),
                ],
                if (cloth.customTags.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(tr(context, 'detail.tags'),
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: cloth.customTags
                        .map((t) => Chip(label: Text('#$t')))
                        .toList(),
                  ),
                ],
                const SizedBox(height: 24),
                // Per-image review cards.
                for (final img in cloth.images) _ImageReviewCard(
                  image: img,
                  busy: _busy.contains(img.id),
                  onAccept: () => _act(img, accept: true),
                  onReject: () => _act(img, accept: false),
                  onEnhance: (mode) => _enhance(img, mode),
                  onEnhanceTier: (mode, tier) =>
                      _enhance(img, mode, tier: tier),
                  onDescribeChanged: (describe) =>
                      _setEnhanceDescribe(img, describe),
                  onAcceptEnhance: () => _acceptEnhance(img),
                  onRejectEnhance: () => _rejectEnhance(img),
                  onTryBetter: () => img.enhanceNextTier == null
                      ? null
                      : _enhance(img, 'ai', tier: img.enhanceNextTier!),
                  onCropRotate: () => _cropRotate(img),
                  onTolerance: (level) => _setTolerance(img, level),
                  onReport: () => _reportImage(img),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// One image + its background-removal review buttons.
class _ImageReviewCard extends StatelessWidget {
  const _ImageReviewCard({
    required this.image,
    required this.busy,
    required this.onAccept,
    required this.onReject,
    required this.onEnhance,
    required this.onEnhanceTier,
    required this.onDescribeChanged,
    required this.onAcceptEnhance,
    required this.onRejectEnhance,
    required this.onTryBetter,
    required this.onCropRotate,
    required this.onTolerance,
    required this.onReport,
  });

  final ClothImage image;
  final bool busy;
  final VoidCallback onAccept;
  final VoidCallback onReject;
  final void Function(String mode) onEnhance;

  /// Same action, with an explicit AI tier — the "try a stronger model" step.
  final void Function(String mode, String tier) onEnhanceTier;

  /// Toggle whether the owner's own description of the garment is put in the
  /// AI prompt. Saved on the image, so a retry repeats the same job.
  final void Function(bool describe) onDescribeChanged;
  final VoidCallback onAcceptEnhance;
  final VoidCallback onRejectEnhance;
  final VoidCallback onTryBetter;
  final VoidCallback onCropRotate;
  final void Function(String level) onTolerance;
  final VoidCallback onReport;

  @override
  Widget build(BuildContext context) {
    final accepted = image.bgAccepted == 'accepted';
    final rejected = image.bgAccepted == 'rejected';
    // Once a choice is made it's final: the user picked cut-out OR original and
    // can't toggle back (they'd replace the photo to redo it). Only a 'pending'
    // image still shows the two choices.
    final decided = accepted || rejected;
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Wrap(spacing: 8, runSpacing: 6, children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(image.role.toUpperCase(),
                    style: const TextStyle(
                        fontSize: 11, fontWeight: FontWeight.bold)),
              ),
              BgStatusBadge(
                  status: image.bgAccepted,
                  cutoutStatus: image.cutoutStatus),
              EnhanceMethodBadge(method: image.enhanceMethod),
            ]),
          ),
          const SizedBox(height: 8),
          Container(
            constraints: const BoxConstraints(minHeight: 220, maxHeight: 320),
            width: double.infinity,
            color: Colors.blueGrey.shade900,
            child: Center(
              // Tap to view fullscreen with pinch-zoom.
              child: GestureDetector(
                onTap: () =>
                    showImageFullscreen(context, imageUrl(image.displayUrl)),
                // AppImage, not Image.network: the latter has no disk cache,
                // so this re-downloaded the full-size image on every visit.
                // displayPreviewUrl is the 800 px copy — indistinguishable
                // here, and ~86 KB instead of ~1 MB.
                child: AppImage(
                  url: imageUrl(image.displayPreviewUrl),
                  cacheKey:
                      'img-${image.id}-${image.bgAccepted}-${image.displayPreviewUrl}',
                  fit: BoxFit.contain,
                  memWidth: 800,   // AppImage draws its own broken-image icon
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: busy ? null : onCropRotate,
              icon: const Icon(Icons.crop_rotate, size: 18),
              label: Text(tr(context, 'detail.cropRotate')),
            ),
          ),
          const SizedBox(height: 10),
          // Background-removal strength — re-runs the cut-out at 3 tolerances.
          Row(children: [
            Text(tr(context, 'detail.cutoutStrength'),
                style: const TextStyle(fontSize: 12, color: Colors.white70)),
            const SizedBox(width: 10),
            Expanded(
              child: SegmentedButton<String>(
                showSelectedIcon: false,
                style: ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  textStyle: WidgetStatePropertyAll(
                      const TextStyle(fontSize: 11)),
                ),
                segments: [
                  ButtonSegment(value: 'low', label: Text(tr(context, 'detail.soft'))),
                  ButtonSegment(value: 'medium', label: Text(tr(context, 'detail.balanced'))),
                  ButtonSegment(value: 'high', label: Text(tr(context, 'detail.strong'))),
                ],
                selected: {image.bgTolerance},
                onSelectionChanged:
                    busy ? null : (s) => onTolerance(s.first),
              ),
            ),
          ]),
          const SizedBox(height: 2),
          Text(tr(context, 'detail.strengthHint'),
              style: const TextStyle(fontSize: 11, color: Colors.grey)),
          const SizedBox(height: 12),
          if (busy)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Center(
                  child: SizedBox(
                      height: 22,
                      width: 22,
                      child: CircularProgressIndicator(strokeWidth: 2))),
            )
          else if (decided)
            // Locked, final choice — no way back to the other version.
            Row(children: [
              Icon(accepted ? Icons.check_circle : Icons.image,
                  size: 18, color: Colors.tealAccent),
              const SizedBox(width: 8),
              Text(
                accepted
                    ? tr(context, 'detail.usingCutout')
                    : tr(context, 'detail.usingOriginal'),
                style: const TextStyle(color: Colors.white70),
              ),
              const Spacer(),
              const Icon(Icons.lock_outline, size: 16, color: Colors.white38),
            ])
          else
            Builder(builder: (ctx) {
              return SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () async {
                    // Screen-sized: these are two small side-by-side
                    // panels, and the stored files are ~1 MB each.
                    final keepCutout = await showCropDecision(ctx,
                        cutoutUrl: image.cutoutPreview,
                        originalUrl: image.originalPreview);
                    if (keepCutout == true) {
                      onAccept();
                    } else if (keepCutout == false) {
                      onReject();
                    }
                  },
                  icon: const Icon(Icons.compare),
                  label: Text(tr(context, 'detail.chooseCrop')),
                ),
              );
            }),
          const Divider(height: 24),
          _enhanceSection(context),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: onReport,
              icon: const Icon(Icons.report_gmailerrorred, size: 16),
              label: Text(tr(context, 'detail.reportTitle'),
                  style: const TextStyle(fontSize: 12)),
              style: TextButton.styleFrom(foregroundColor: Colors.orangeAccent),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _beforeAfterTile(BuildContext context, String label, String url, Color? tint) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Text(label,
          style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: tint ?? Colors.white70)),
      const SizedBox(height: 4),
      GestureDetector(
        onTap: () => showImageFullscreen(context, imageUrl(url)),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Container(
            height: 170,
            color: Colors.blueGrey.shade900,
            alignment: Alignment.center,
            child: AppImage(
              url: imageUrl(url),
              cacheKey: 'ba-$url',
              fit: BoxFit.contain,
              memWidth: 800,
            ),
          ),
        ),
      ),
    ]);
  }

  /// Opt-in photo enhancement: a button (Auto/AI) when idle, a spinner while
  /// running, or a side-by-side candidate with keep/discard when ready.
  Widget _enhanceSection(BuildContext context) {
    final status = image.enhanceStatus;
    if (status == 'processing') {
      // The server gives up on its own now, so this cannot spin forever — but
      // the way out is offered here as well: a retry re-runs it from scratch,
      // which is the only useful thing to do with one that is taking too long.
      return Row(children: [
        const SizedBox(
            height: 18,
            width: 18,
            child: CircularProgressIndicator(strokeWidth: 2)),
        const SizedBox(width: 10),
        Expanded(
          child: Text(tr(context, 'detail.enhancing'),
              style: const TextStyle(color: Colors.white70)),
        ),
        TextButton(
          onPressed: () => onEnhance(image.enhancePendingMethod ?? 'auto'),
          child: Text(tr(context, 'detail.enhanceRetry')),
        ),
      ]);
    }
    if (status == 'ready' && image.enhancedUrl.isNotEmpty) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(tr(context, 'detail.enhancedCompare'),
            style: const TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: _beforeAfterTile(context,
                tr(context, 'detail.before'),
                image.displayPreviewUrl ?? image.originalPreview, null),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _beforeAfterTile(context,
                tr(context, 'detail.after'), image.enhancedPreview, Colors.tealAccent),
          ),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: onAcceptEnhance,
              icon: const Icon(Icons.check),
              label: Text(tr(context, 'detail.keep')),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: onRejectEnhance,
              icon: const Icon(Icons.close),
              label: Text(tr(context, 'detail.discard')),
            ),
          ),
        ]),
        if (image.enhancePendingMethod == 'ai' && image.enhanceNextTier != null) ...[
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: onTryBetter,
              icon: const Icon(Icons.upgrade),
              label: Text('${tr(context, 'detail.tryBetterModel')} '
                  '(${enhanceTierLabel(image.enhanceNextTier!)})'),
            ),
          ),
        ],
      ]);
    }
    // idle or failed → offer to (re)run
    if (status == 'failed') {
      // Reported: some garments "ne veulent pas s'améliorer avec l'IA et
      // mettent sans cesse fail même après réessayer". Retrying the identical
      // request is exactly what does not help there, so the step up to a
      // stronger model sits right next to it — and the server's own reason is
      // shown, because "failed" on its own leaves nothing to decide with.
      final nextTier = image.enhanceNextTier;
      final lastMethod = image.enhancePendingMethod ?? 'auto';
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.error_outline, size: 18, color: Colors.redAccent),
          const SizedBox(width: 6),
          Expanded(
            child: Text(tr(context, 'detail.enhanceTimedOut'),
                style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
          ),
        ]),
        if ((image.enhanceError ?? '').isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 24),
            child: Text(image.enhanceError!,
                style: const TextStyle(color: Colors.white54, fontSize: 11)),
          ),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.tonalIcon(
            onPressed: () => onEnhance(lastMethod),
            icon: const Icon(Icons.refresh, size: 18),
            label: Text(tr(context, 'detail.enhanceRetry')),
          ),
          if (nextTier != null)
            FilledButton.icon(
              onPressed: () => onEnhanceTier('ai', nextTier),
              icon: const Icon(Icons.upgrade, size: 18),
              label: Text(tr(context, 'detail.enhanceRetryStronger',
                  {'tier': enhanceTierLabel(nextTier)})),
            )
          else if (lastMethod != 'ai')
            // The deterministic pass failed; the AI one is a different engine
            // entirely, so it is worth offering rather than repeating.
            FilledButton.icon(
              onPressed: () => onEnhanceTier('ai', 'flex'),
              icon: const Icon(Icons.auto_awesome, size: 18),
              label: Text(tr(context, 'detail.enhanceTryAi')),
            ),
          _enhanceMenu(context),
        ]),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _describeToggle(context),
      const SizedBox(height: 4),
      Row(children: [_enhanceMenu(context)]),
    ]);
  }

  /// Whether the AI prompt names what the owner typed about this garment.
  ///
  /// Sits next to the button rather than behind a dialog: it is one tap, it is
  /// remembered per image, and it only changes what the AI pass is told — the
  /// deterministic pass builds no prompt at all, which is why the line says so.
  Widget _describeToggle(BuildContext context) {
    return InkWell(
      onTap: () => onDescribeChanged(!image.enhanceDescribe),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
            width: 24,
            height: 24,
            child: Checkbox(
              value: image.enhanceDescribe,
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              onChanged: (v) => onDescribeChanged(v ?? true),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(tr(context, 'detail.describeItem'),
                style: const TextStyle(color: Colors.white70, fontSize: 12)),
          ),
        ]),
      ),
    );
  }

  /// The Auto / AI chooser. Shared by the idle state and the failed one, where
  /// it sits next to the retry button so a different method is one tap away.
  Widget _enhanceMenu(BuildContext context) {
    return PopupMenuButton<String>(
      onSelected: onEnhance,
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'auto',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.auto_fix_high),
            title: Text(tr(context, 'detail.autoCleanup')),
            subtitle: Text(tr(context, 'detail.autoCleanupSub')),
          ),
        ),
        PopupMenuItem(
          value: 'ai',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.auto_awesome),
            title: Text(tr(context, 'detail.aiEnhance')),
            subtitle: Text(tr(context, 'detail.aiEnhanceSub')),
          ),
        ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.white38),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.auto_fix_high, size: 18),
          const SizedBox(width: 8),
          Text(image.enhanceStatus == 'failed'
              ? tr(context, 'detail.otherMethod')
              : tr(context, 'detail.improvePhoto')),
        ]),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white12,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text('$label: $value',
          style: const TextStyle(fontSize: 12, color: Colors.white70)),
    );
  }
}