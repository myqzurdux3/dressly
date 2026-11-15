import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../config/api_config.dart';
import '../../design/ds.dart';
import '../../l10n/app_text.dart';
import '../../models/cloth.dart';
import '../../services/clothes_service.dart' show ClothWears;
import '../wardrobe/wardrobe_card.dart' show swatchColorOf;
import 'add_cloth_screen.dart'; // ClothFormScreen
import 'detail/cloth_detail_state.dart';
import 'detail/detail_image_panel.dart';
import 'photo_edit_screen.dart';

/// One garment: a hero on its own colour, the facts (rating, wear, colours,
/// tags), then every photo with its tools. Pops `true` when deleted.
class ClothDetailScreen extends ConsumerStatefulWidget {
  const ClothDetailScreen({
    super.key,
    required this.clothId,
    this.imageBuilder = detailAppImage,
  });

  final int clothId;

  /// Overrides how images are drawn (tests).
  final DetailImageBuilder imageBuilder;

  @override
  ConsumerState<ClothDetailScreen> createState() => _ClothDetailScreenState();
}

class _ClothDetailScreenState extends ConsumerState<ClothDetailScreen> {
  /// Photos whose cut-out call is in flight. Rapid taps used to queue
  /// conflicting requests that left the photo blank.
  final Set<int> _busy = {};

  ClothDetail get _ctrl =>
      ref.read(clothDetailProvider(widget.clothId).notifier);

  void _toast(String key, [Object? err]) {
    if (!mounted) return;
    final msg = tr(context, key);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(err == null ? msg : '$msg: $err')));
  }

  /// Runs [action]; on failure says [failKey] with the error.
  Future<void> _run(
    Future<void> Function() action, {
    String failKey = 'detail.failed',
    String? doneKey,
  }) async {
    try {
      await action();
      if (doneKey != null) _toast(doneKey);
    } catch (e) {
      _toast(failKey, e);
    }
  }

  /// Same, with the photo's controls disabled while it runs.
  Future<void> _runOnImage(
    ClothImage img,
    Future<void> Function() action, {
    String failKey = 'detail.failed',
    String? doneKey,
  }) async {
    if (_busy.contains(img.id)) return; // double tap
    setState(() => _busy.add(img.id));
    try {
      await _run(action, failKey: failKey, doneKey: doneKey);
    } finally {
      if (mounted) setState(() => _busy.remove(img.id));
    }
  }

  Future<void> _edit(Cloth cloth) async {
    await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => ClothFormScreen(initial: cloth)),
    );
    // Always: the form saves photo changes live, so the garment can have
    // changed even when the user backs out without saving.
    if (mounted) await _ctrl.reload();
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr(context, 'detail.deleteTitle')),
        content: Text(tr(context, 'detail.deleteConfirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(tr(context, 'common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(tr(context, 'common.delete')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await _ctrl.delete();
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      _toast('detail.deleteFailed', e);
    }
  }

  Future<void> _cropRotate(ClothImage img) async {
    final updated = await Navigator.push<Cloth>(
      context,
      MaterialPageRoute(
        builder: (_) => PhotoEditScreen(clothId: widget.clothId, image: img),
      ),
    );
    // The crop endpoint returns the garment: shown as is, no refetch.
    if (updated != null && mounted) _ctrl.apply(updated);
  }

  Future<void> _report(ClothImage img) async {
    final ctrl = TextEditingController();
    bool? ok;
    var message = '';
    try {
      ok = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(tr(context, 'detail.reportTitle')),
          content: TextField(
            controller: ctrl,
            maxLines: 2,
            decoration: InputDecoration(
              hintText: tr(context, 'detail.reportHint'),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(tr(context, 'common.cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(tr(context, 'detail.sendToAdmins')),
            ),
          ],
        ),
      );
      message = ctrl.text.trim();
    } finally {
      ctrl.dispose();
    }
    if (ok != true) return;
    await _run(
      () => _ctrl.reportImage(img, message),
      failKey: 'detail.reportFailed',
      doneKey: 'detail.reported',
    );
  }

  Future<void> _showWears() async {
    final ClothWears w;
    try {
      w = await _ctrl.wears();
    } catch (_) {
      return; // as before: nothing to show, nothing worth an error
    }
    if (!mounted) return;
    final ds = context.ds;
    await showDsSheet<void>(
      context,
      title:
          '${tr(context, 'detail.worn')} ${w.total} '
          '${trPlural(context, 'detail.day', w.total)} · '
          '${w.thisYear} ${tr(context, 'detail.thisYear')}',
      child: w.days.isEmpty
          ? Text(
              tr(context, 'detail.notWornYet'),
              style: ds.typo.body.copyWith(color: ds.colors.textMuted),
            )
          : Wrap(
              spacing: ds.space.xs,
              runSpacing: ds.space.xs,
              children: [for (final d in w.days) _Pill(text: d)],
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final async = ref.watch(clothDetailProvider(widget.clothId));
    return Scaffold(
      backgroundColor: ds.colors.bg,
      body: switch (async) {
        AsyncValue(:final value?) => _content(context, value),
        AsyncValue(:final error?) => SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _BackButton(),
              Expanded(
                child: DsError(
                  message: '${tr(context, 'detail.error')}: $error',
                  retryLabel: tr(context, 'common.retry'),
                  onRetry: () =>
                      ref.invalidate(clothDetailProvider(widget.clothId)),
                ),
              ),
            ],
          ),
        ),
        _ => SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _BackButton(),
              Expanded(
                child: Center(
                  child: CircularProgressIndicator(color: ds.colors.accent),
                ),
              ),
            ],
          ),
        ),
      },
    );
  }

  Widget _content(BuildContext context, Cloth cloth) {
    final ds = context.ds;
    final c = ds.colors;
    final tone = garmentTone(
      swatchColorOf(cloth),
      Theme.of(context).brightness,
    );
    final front =
        cloth.images.where((i) => i.role == 'front').firstOrNull ??
        cloth.images.firstOrNull;
    final heroPath = front?.displayPreviewUrl;
    final pad = EdgeInsets.symmetric(horizontal: ds.space.gutter);

    return RefreshIndicator(
      color: c.accent,
      onRefresh: _ctrl.reload,
      child: ListView(
        padding: EdgeInsets.only(bottom: ds.space.xxl),
        children: [
          // Hero: the garment on its own colour, actions over it.
          Container(
            height: 360,
            decoration: BoxDecoration(
              color: tone.fill,
              borderRadius: BorderRadius.vertical(
                bottom: Radius.circular(ds.shape.hero),
              ),
            ),
            child: SafeArea(
              bottom: false,
              child: Column(
                children: [
                  Padding(
                    padding: EdgeInsets.all(ds.space.s),
                    child: Row(
                      children: [
                        const _BackButton(),
                        const Spacer(),
                        DsButton.icon(
                          icon: cloth.isFavorite
                              ? Icons.favorite
                              : Icons.favorite_border,
                          semanticLabel: tr(context, 'detail.favorite'),
                          onPressed: () => _run(_ctrl.toggleFavorite),
                        ),
                        SizedBox(width: ds.space.xs),
                        DsButton.icon(
                          icon: Icons.edit_outlined,
                          semanticLabel: tr(context, 'form.editTitle'),
                          onPressed: () => _edit(cloth),
                        ),
                        SizedBox(width: ds.space.xs),
                        DsButton.icon(
                          icon: Icons.delete_outline,
                          semanticLabel: tr(context, 'common.delete'),
                          onPressed: _delete,
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        ds.space.xl,
                        0,
                        ds.space.xl,
                        ds.space.l,
                      ),
                      child: heroPath == null
                          ? Icon(Icons.checkroom, size: 96, color: tone.shade)
                          : widget.imageBuilder(
                              imageUrl(heroPath),
                              'hero-${front!.id}-${front.bgAccepted}-$heroPath',
                              800,
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(height: ds.space.l),
          Padding(
            padding: pad,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(cloth.name.toUpperCase(), style: ds.typo.headline),
                if (cloth.brand.isNotEmpty) ...[
                  SizedBox(height: ds.space.xs),
                  Text(
                    cloth.brand.toUpperCase(),
                    style: ds.typo.mono.copyWith(color: c.textMuted),
                  ),
                ],
                SizedBox(height: ds.space.m),
                Wrap(
                  spacing: ds.space.xs,
                  runSpacing: ds.space.xs,
                  children: [
                    if (cloth.category.isNotEmpty)
                      _Pill(text: categoryName(context, cloth.category)),
                    if (categoryHasCut(cloth.category) && cloth.cut.isNotEmpty)
                      _Pill(text: cutLabel(context, cloth.cut)),
                    for (final col in cloth.colors)
                      _Pill(
                        text:
                            '${colorName(context, col.color)} · '
                            '${dominanceLabel(context, col.dominance)}',
                        dot: garmentTone(
                          col.color,
                          Theme.of(context).brightness,
                        ).fill,
                      ),
                    for (final t in cloth.customTags) _Pill(text: '#$t'),
                  ],
                ),
                DsSectionTitle(tr(context, 'detail.rating')),
                DsRating(
                  score: cloth.score,
                  onChanged: (v) => _run(
                    () => _ctrl.setScore(v),
                    failKey: 'detail.ratingFailed',
                  ),
                ),
                DsSectionTitle(tr(context, 'detail.worn')),
                Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        onTap: _showWears,
                        child: Padding(
                          padding: EdgeInsets.symmetric(vertical: ds.space.s),
                          child: Text(
                            cloth.lastWornAt == null
                                ? tr(context, 'detail.neverWorn')
                                : '${tr(context, 'detail.lastWorn')} '
                                      '${cloth.lastWornAt} · '
                                      '${tr(context, 'detail.tapForHistory')}',
                            style: ds.typo.body.copyWith(
                              color: c.textMuted,
                              decoration: TextDecoration.underline,
                            ),
                          ),
                        ),
                      ),
                    ),
                    SizedBox(width: ds.space.s),
                    DsButton(
                      label: tr(context, 'detail.wornToday'),
                      icon: Icons.checkroom,
                      kind: DsButtonKind.secondary,
                      onPressed: () =>
                          _run(_ctrl.wearToday, doneKey: 'detail.markedWorn'),
                    ),
                  ],
                ),
                SizedBox(height: ds.space.m),
                // Out of the generators, still usable by hand.
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            tr(context, 'detail.excludeAlgo'),
                            style: ds.typo.bodyStrong,
                          ),
                          Text(
                            tr(context, 'detail.excludeAlgoHint'),
                            style: ds.typo.label.copyWith(color: c.textMuted),
                          ),
                        ],
                      ),
                    ),
                    Switch(
                      value: cloth.excludeFromAlgo,
                      activeTrackColor: c.accent,
                      onChanged: (v) => _run(() => _ctrl.setExcludeFromAlgo(v)),
                    ),
                  ],
                ),
                DsSectionTitle(tr(context, 'detail.photos')),
                if (cloth.images.isEmpty)
                  Text(
                    tr(context, 'detail.noImages'),
                    style: ds.typo.body.copyWith(color: c.textMuted),
                  ),
                for (final img in cloth.images)
                  DetailImagePanel(
                    key: ValueKey(img.id),
                    image: img,
                    busy: _busy.contains(img.id),
                    imageBuilder: widget.imageBuilder,
                    onDecide: (keepCutout) => _runOnImage(
                      img,
                      () => _ctrl.decideCutout(img, accept: keepCutout),
                      failKey: 'detail.actionFailed',
                      doneKey: keepCutout
                          ? 'detail.cutoutKept'
                          : 'detail.keepingOriginal',
                    ),
                    onCropRotate: () => _cropRotate(img),
                    onTolerance: (level) => _runOnImage(
                      img,
                      () => _ctrl.setTolerance(img, level),
                      doneKey: 'detail.bgRedone',
                    ),
                    onEnhance: (mode, tier) => _run(
                      () => _ctrl.enhance(img, mode, tier: tier),
                      failKey: 'detail.enhanceFailed',
                    ),
                    onDescribeChanged: (d) => _run(
                      () => _ctrl.setEnhanceDescribe(img, d),
                      failKey: 'detail.enhanceFailed',
                    ),
                    onAcceptEnhance: () => _run(
                      () => _ctrl.acceptEnhance(img),
                      doneKey: 'detail.enhanceApplied',
                    ),
                    onRejectEnhance: () => _run(() => _ctrl.rejectEnhance(img)),
                    onReport: () => _report(img),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BackButton extends StatelessWidget {
  const _BackButton();

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.all(context.ds.space.xs),
    child: DsButton.icon(
      icon: Icons.arrow_back,
      semanticLabel: MaterialLocalizations.of(context).backButtonTooltip,
      onPressed: () => Navigator.maybePop(context),
    ),
  );
}

/// A fact about the garment, optionally with a colour dot.
class _Pill extends StatelessWidget {
  const _Pill({required this.text, this.dot});

  final String text;
  final Color? dot;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: ds.space.s,
        vertical: ds.space.xs,
      ),
      decoration: BoxDecoration(
        color: ds.colors.surface,
        borderRadius: BorderRadius.circular(ds.shape.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot != null) ...[
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: dot,
                shape: BoxShape.circle,
                border: Border.all(color: ds.colors.hairline),
              ),
            ),
            SizedBox(width: ds.space.xs),
          ],
          Text(text, style: ds.typo.label),
        ],
      ),
    );
  }
}
