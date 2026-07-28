import 'package:flutter/material.dart';

import '../../app.dart';
import '../../config/api_config.dart';
import '../../l10n/app_text.dart';
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
      return c;
    });
    setState(() {
      _future = future;
    });
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
    if (updated != null && mounted) _reload();
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
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(child: Text('${tr(context, 'detail.error')}: ${snap.error}'));
          }
          final cloth = snap.data!;
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
              BgStatusBadge(status: image.bgAccepted),
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
                child: Image.network(
                  imageUrl(image.displayUrl),
                  key: ValueKey(
                      'img-${image.id}-${image.bgAccepted}-${image.displayUrl}'),
                  fit: BoxFit.contain,
                  loadingBuilder: (context, child, p) {
                    if (p == null) return child;
                    return const SizedBox(
                        height: 220, child: Center(child: CircularProgressIndicator()));
                  },
                  errorBuilder: (context, _, __) => const Icon(Icons.broken_image,
                      size: 48, color: Colors.white54),
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
                    final keepCutout = await showCropDecision(ctx,
                        cutoutUrl: image.cutoutUrl,
                        originalUrl: image.originalUrl);
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
            child: Image.network(
              imageUrl(url),
              key: ValueKey('ba-$url'),
              fit: BoxFit.contain,
              errorBuilder: (c, _, __) =>
                  const Icon(Icons.broken_image, color: Colors.white54),
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
      return Row(children: [
        const SizedBox(
            height: 18,
            width: 18,
            child: CircularProgressIndicator(strokeWidth: 2)),
        const SizedBox(width: 10),
        Text(tr(context, 'detail.enhancing'), style: const TextStyle(color: Colors.white70)),
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
                tr(context, 'detail.before'), image.displayUrl ?? image.originalUrl, null),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _beforeAfterTile(context,
                tr(context, 'detail.after'), image.enhancedUrl, Colors.tealAccent),
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
    return Row(children: [
      if (status == 'failed') ...[
        const Icon(Icons.error_outline, size: 18, color: Colors.redAccent),
        const SizedBox(width: 6),
        Text(tr(context, 'detail.enhanceFailed'),
            style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
        const Spacer(),
      ],
      PopupMenuButton<String>(
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
            Text(status == 'failed' ? tr(context, 'detail.retry') : tr(context, 'detail.improvePhoto')),
          ]),
        ),
      ),
    ]);
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