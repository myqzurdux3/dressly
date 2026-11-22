import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../app.dart';
import '../../design/ds.dart';
import '../../l10n/app_text.dart';
import '../../models/cloth.dart';
import '../../models/model.dart';
import '../../models/outfit.dart';
import '../../services/outfits_service.dart';
import '../../widgets/outfit_viewer.dart';
import '../cloth/cloth_detail_screen.dart';
import 'cloth_picker_screen.dart';
import 'outfit_collage.dart';
import '../../widgets/app_image.dart';
import '../../widgets/outfit_pending_image.dart';
import '../../widgets/render_person_sheet.dart';
import '../../state/data_bus.dart';
import '../../state/session.dart';
import 'manual_builder_screen.dart';
import '../../widgets/error_toast.dart';

class OutfitResultDialog extends StatefulWidget {
  const OutfitResultDialog({
    super.key,
    required this.outfit,
    required this.onChanged,
    this.onOpenManual,
    this.startWithAi = false,
  });

  /// Opened right after the builder's "AI" button: go straight to the AI
  /// version (shown if it exists, else rendered).
  final bool startWithAi;

  final Outfit outfit;
  final ValueChanged<Outfit> onChanged;
  // Convert this outfit into a manual one (AI -> manual), editing it in place.
  final ValueChanged<Outfit>? onOpenManual;

  @override
  State<OutfitResultDialog> createState() => _OutfitResultDialogState();
}

class _OutfitResultDialogState extends State<OutfitResultDialog> {
  late Outfit _outfit;
  bool _busy = false;
  bool _wornToday = false;
  bool _reported = false;

  /// The garments with their pictures, for the collage of an outfit that has
  /// no render yet. Loaded once; empty until then (or on failure).
  List<Cloth> _pieces = const [];

  @override
  void initState() {
    super.initState();
    _outfit = widget.outfit;
    _wornToday = widget.outfit.wornToday;
    if (!_outfit.hasRender && _outfit.status != 'failed') _loadPieces();
    // A failed render of a montage leaves the montage shown with the error.
    if (_outfit.isManual && _outfit.error.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => toast(_outfit.error),
      );
    }
    if (_outfit.isProcessing) _waitForRender();
    if (widget.startWithAi) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _switchVersion('ai'));
    }
  }

  /// Which version is on screen: the AI render or the hand-made montage.
  String get _version => _outfit.isManual ? 'manual' : 'ai';

  /// Switch between the AI render and the montage. A version that exists is
  /// just shown; a missing montage opens the builder on a tidy flat lay of
  /// these clothes; a missing render asks who wears it and renders it on
  /// this same outfit. Nothing is redone by hand either way.
  Future<void> _switchVersion(String v) async {
    if (_busy || _outfit.isProcessing) return;
    if (v == 'manual' && !_outfit.hasManual) return _editMontage();
    if (v == _version && !(v == 'ai' && !_outfit.hasAi)) return;
    final svc = outfitsServiceOf(context);
    if ((v == 'ai' && _outfit.hasAi) || v == 'manual') {
      final o = await _run(
        'result.failed',
        () => svc.showVersion(_outfit.id, v),
      );
      if (o == null || !mounted) return;
      setState(() => _outfit = o);
      widget.onChanged(o);
      DataBus.outfitsChanged();
      return;
    }
    final tier = genPrefsOf(context).startTier;
    final person = await pickRenderPerson(context);
    if (person == null || !mounted) return;
    final o = await _run(
      'result.generationFailed',
      () => svc.renderInPlace(
        _outfit.id,
        modelId: int.tryParse(person),
        randomModel: person == 'random',
        tier: tier,
      ),
    );
    if (o == null || !mounted) return;
    setState(() => _outfit = o);
    widget.onChanged(o);
    DataBus.outfitsChanged();
    _waitForRender();
  }

  /// Open this outfit's montage in the builder (a flat lay of its clothes
  /// when it has none yet). Saving keeps the AI render beside it.
  Future<void> _editMontage() async {
    final res = await Navigator.of(context).push<ManualBuilderResult>(
      MaterialPageRoute(builder: (_) => ManualBuilderScreen(existing: _outfit)),
    );
    final saved = res?.saved;
    if (saved == null || !mounted) return;
    setState(() => _outfit = saved);
    widget.onChanged(saved);
    DataBus.outfitsChanged();
    if (res!.thenAi) _switchVersion('ai');
  }

  /// Opened while the render runs (from the stylist, or a list): show the
  /// garments until it lands, then the picture.
  Future<void> _waitForRender() async {
    final svc = outfitsServiceOf(context);
    try {
      final done = await svc.getAwait(_outfit.id, cancelled: () => !mounted);
      if (!mounted) return;
      setState(() => _outfit = done);
      widget.onChanged(done);
      DataBus.outfitsChanged();
      if (done.isManual && done.error.isNotEmpty) toast(done.error);
    } catch (_) {
      // The list still refreshes on its own; nothing to report here.
    }
  }

  Future<void> _loadPieces() async {
    final svc = clothesServiceOf(context);
    try {
      final got = await Future.wait(_outfit.clothIds.take(4).map(svc.get));
      if (mounted) setState(() => _pieces = got);
    } catch (_) {
      // Decoration only: without pictures the panel still offers the render.
    }
  }

  /// Run [action] with the dialog disabled, reporting any failure under
  /// [errorKey]. Returns null when the action was skipped (already busy) or
  /// threw.
  ///
  /// Every action here repeated this guard/try/finally by hand. Centralising it
  /// is not just tidiness: one forgotten `finally` leaves `_busy` stuck true and
  /// the whole dialog permanently unusable.
  Future<T?> _run<T>(String errorKey, Future<T> Function() action) async {
    if (_busy) return null;
    setState(() => _busy = true);
    try {
      return await action();
    } catch (e) {
      toastError(e, prefixKey: errorKey);
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// [_run] for the common case: the action yields the updated outfit, which
  /// becomes this dialog's state and is handed to the parent screen.
  Future<Outfit?> _runUpdating(
    String errorKey,
    Future<Outfit> Function() action,
  ) async {
    final updated = await _run(errorKey, action);
    if (updated == null || !mounted) return null;
    setState(() {
      _outfit = updated;
      _wornToday = updated.wornToday;
    });
    widget.onChanged(updated);
    return updated;
  }

  /// Re-run a FAILED generation at the same level (the backend still cascades
  /// up on failure). The outfit's clothes/model/prompt are untouched.
  Future<void> _retryGeneration() => _runUpdating(
    'result.retryFailed',
    () => outfitsServiceOf(context).regenerate(
      _outfit.id,
      tier: _outfit.modelTier,
      cancelled: () => !mounted,
    ),
  );

  Future<void> _regenerate() => _runUpdating(
    'result.regenerateFailed',
    () => outfitsServiceOf(
      context,
    ).regenerate(_outfit.id, cancelled: () => !mounted),
  );

  /// Flip "describe items to the AI" and re-render at the same tier.
  Future<void> _toggleDescribe(bool value) => _runUpdating(
    'result.failed',
    () => outfitsServiceOf(context).regenerate(
      _outfit.id,
      tier: _outfit.modelTier,
      describeClothes: value,
      cancelled: () => !mounted,
    ),
  );

  /// Re-render the SAME outfit at its current tier with a changed reference-image
  /// mode and/or top-render subset (the controls that used to live only on the
  /// create screen, now available after generation too).
  Future<void> _reRenderWith({String? imageMode, List<int>? renderClothIds}) =>
      _runUpdating(
        'result.failed',
        () => outfitsServiceOf(context).regenerate(
          _outfit.id,
          tier: _outfit.modelTier,
          imageMode: imageMode,
          renderClothIds: renderClothIds,
          cancelled: () => !mounted,
        ),
      );

  Future<void> _setImageMode(String mode) async {
    if (mode == _outfit.imageMode) return;
    await _reRenderWith(imageMode: mode);
  }

  /// Upper-body garments in this outfit (base/mid/outer) — the ones the
  /// "which top to render" chooser toggles.
  List<OutfitCloth> get _upperCloths =>
      _outfit.cloths.where((c) => isUpperBody(c.category)).toList()..sort(
        (a, b) => bodyOrder(a.category).compareTo(bodyOrder(b.category)),
      );

  bool _isRendered(int clothId) =>
      _outfit.renderClothIds.isEmpty ||
      _outfit.renderClothIds.contains(clothId);

  Future<void> _toggleTopRender(int clothId, bool render) async {
    final rendered = _outfit.renderClothIds.isEmpty
        ? _outfit.clothIds.toSet()
        : _outfit.renderClothIds.toSet();
    if (render) {
      rendered.add(clothId);
    } else {
      // Keep at least one upper layer visible.
      final visibleUppers = _upperCloths
          .where((c) => rendered.contains(c.id))
          .length;
      if (visibleUppers <= 1) return;
      rendered.remove(clothId);
    }
    final all = _outfit.clothIds.toSet();
    final renderList = rendered.containsAll(all)
        ? <int>[] // everything rendered → clear the subset
        : _outfit.clothIds.where(rendered.contains).toList();
    await _reRenderWith(renderClothIds: renderList);
  }

  Future<void> _generateBack() async {
    if (_busy) return;
    if (_outfit.modelId == null) {
      // A plain snackbar would render behind this dialog; use a modal that
      // stacks on top so the message is fully visible.
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr(context, 'result.pickOwnModel')),
          content: Text(tr(context, 'result.backNeedsModel')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr(context, 'result.notNow')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr(context, 'result.chooseModel')),
            ),
          ],
        ),
      );
      if (go == true && mounted) await _changeModel();
      return;
    }
    final back = await _runUpdating(
      'result.backFailed',
      () => outfitsServiceOf(
        context,
      ).generateBack(_outfit.id, cancelled: () => !mounted),
    );
    if (back != null) toastKey('result.backCreated');
  }

  Future<void> _switchLinkedView() async {
    if (_outfit.linkedId == null) return;
    // Await completion: editing clothes on one view re-renders the other, so
    // the linked outfit may still be processing when we switch to it.
    await _runUpdating(
      'result.failed',
      () => outfitsServiceOf(
        context,
      ).getAwait(_outfit.linkedId!, cancelled: () => !mounted),
    );
  }

  Future<void> _markWorn() async {
    if (_wornToday) return;
    final ok = await _run('result.failed', () async {
      await outfitsServiceOf(context).wear(_outfit.id);
      return true;
    });
    if (ok == true && mounted) {
      setState(() => _wornToday = true);
      toastKey('result.markedWorn');
    }
  }

  /// Show every day this outfit was worn + counts (mirrors the per-cloth sheet).
  Future<void> _showWearHistory() async {
    final OutfitWears wears;
    try {
      wears = await outfitsServiceOf(context).wears(_outfit.id);
    } catch (e) {
      // Silently ignored before: the button simply did nothing.
      toastError(e, prefixKey: 'result.loadFailed');
      return;
    }
    if (!mounted) return;
    showDsSheet<void>(
      context,
      title: tr(context, 'result.wornCount')
          .replaceFirst('{n}', '${wears.total}')
          .replaceFirst('{y}', '${wears.thisYear}'),
      child: Builder(
        builder: (ctx) {
          final ds = ctx.ds;
          if (wears.days.isEmpty) {
            return Text(
              tr(ctx, 'result.notWornYet'),
              style: ds.typo.label.copyWith(color: ds.colors.textMuted),
            );
          }
          return Wrap(
            spacing: ds.space.xs,
            runSpacing: ds.space.xs,
            children: [for (final d in wears.days) DsBadge(text: d)],
          );
        },
      ),
    );
  }

  /// Make a public link and hand it to the user, with the way to take it back
  /// in the same place — a link you cannot revoke is not one you want to send.
  Future<void> _share() async {
    final svc = outfitsServiceOf(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final shared = await svc.share(_outfit.id);
      if (!mounted) return;
      setState(() => _busy = false);
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr(ctx, 'share.title')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(tr(ctx, 'share.explain')),
              const SizedBox(height: 12),
              SelectableText(shared.url, style: ctx.ds.typo.monoSmall),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () async {
                // Resolved before the await: the dialog's context is gone by
                // the time the call returns.
                final revoked = tr(ctx, 'share.revoked');
                await svc.unshare(_outfit.id);
                if (ctx.mounted) Navigator.pop(ctx);
                messenger.showSnackBar(SnackBar(content: Text(revoked)));
              },
              child: Text(tr(ctx, 'share.revoke')),
            ),
            FilledButton(
              onPressed: () async {
                final copied = tr(ctx, 'share.copied');
                await Clipboard.setData(ClipboardData(text: shared.url));
                if (ctx.mounted) Navigator.pop(ctx);
                messenger.showSnackBar(SnackBar(content: Text(copied)));
              },
              child: Text(tr(ctx, 'share.copy')),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      toastError(e);
    }
  }

  Future<void> _toggleFav() async {
    final newVal = await _run(
      'result.favoriteFailed',
      () => outfitsServiceOf(
        context,
      ).toggleFavorite(_outfit.id, isFavorite: !_outfit.isFavorite),
    );
    if (newVal == null || !mounted) return;
    setState(() => _outfit = _outfit.copyWith(isFavorite: newVal));
    widget.onChanged(_outfit);
    toastKey(newVal ? 'result.favAdded' : 'result.favRemoved');
  }

  Future<void> _rate(int rating) async {
    final before = _outfit.rating;
    // Optimistic: the stars move on tap, and go back if the call fails.
    setState(() => _outfit = _outfit.copyWith(rating: rating));
    final saved = await _run(
      'result.rateFailed',
      () => outfitsServiceOf(context).rate(_outfit.id, rating),
    );
    if (!mounted) return;
    setState(() => _outfit = _outfit.copyWith(rating: saved ?? before));
    widget.onChanged(_outfit);
  }

  Future<void> _toggleBlacklist() async {
    final newVal = await _run(
      'result.failed',
      () => outfitsServiceOf(
        context,
      ).setBlacklist(_outfit.id, blacklisted: !_outfit.isBlacklisted),
    );
    if (newVal == null || !mounted) return;
    setState(() => _outfit = _outfit.copyWith(isBlacklisted: newVal));
    widget.onChanged(_outfit);
    toastKey(newVal ? 'result.bannedToast' : 'result.allowedAgain');
  }

  /// Ask for an extra instruction (pose, angle, setting…) and re-render at the
  /// same model level with it folded into the prompt.
  Future<void> _regenerateWithDetail() async {
    if (_busy) return;
    final ctrl = TextEditingController();
    final String? detail;
    // The controller belongs to the dialog, not to this state, so it has to be
    // disposed once the dialog is gone — otherwise every "add detail" leaks one.
    try {
      detail = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr(context, 'result.addDetailTitle')),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            maxLines: 2,
            decoration: InputDecoration(
              hintText: tr(context, 'result.addDetailHint'),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr(context, 'common.cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: Text(tr(context, 'result.regenerate')),
            ),
          ],
        ),
      );
    } finally {
      ctrl.dispose();
    }
    if (detail == null || detail.isEmpty || !mounted) return;
    await _runUpdating(
      'result.regenerateFailed',
      () => outfitsServiceOf(context).regenerate(
        _outfit.id,
        tier: _outfit.modelTier,
        addDetail: detail,
        cancelled: () => !mounted,
      ),
    );
  }

  Future<void> _addToAgenda() async {
    if (_busy) return;
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 2),
    );
    if (picked == null || !mounted) return;
    final day =
        '${picked.year.toString().padLeft(4, '0')}-'
        '${picked.month.toString().padLeft(2, '0')}-'
        '${picked.day.toString().padLeft(2, '0')}';
    final ok = await _run('result.agendaFailed', () async {
      await agendaServiceOf(context).create(day: day, outfitId: _outfit.id);
      return true;
    });
    if (ok == true && mounted) {
      toast('${tr(context, 'result.addedAgenda')} $day ✓');
    }
  }

  Future<void> _removeCloth(int clothId) async {
    if (_busy) return;
    final remaining = _outfit.clothIds.where((id) => id != clothId).toList();
    if (remaining.isEmpty) {
      toastKey('result.needOneCloth');
      return;
    }
    await _runUpdating(
      'result.removeFailed',
      () => outfitsServiceOf(
        context,
      ).replaceClothes(_outfit.id, remaining, cancelled: () => !mounted),
    );
  }

  Future<void> _editClothes() async {
    if (_busy) return;
    final svc = outfitsServiceOf(context);
    final picked = await Navigator.push<Set<int>>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            ClothPickerScreen(initialSelected: _outfit.clothIds.toSet()),
      ),
    );
    if (picked == null || picked.isEmpty) return;
    await _runUpdating(
      'result.regenerateFailed',
      () => svc.replaceClothes(
        _outfit.id,
        picked.toList(),
        cancelled: () => !mounted,
      ),
    );
  }

  /// Swap the person the outfit is rendered on (or drop the model) and
  /// re-render — the counterpart to "Add / swap clothes".
  Future<void> _changeModel() async {
    if (_busy) return;
    List<ModelEntity> models;
    try {
      models = await modelsServiceOf(context).list();
    } catch (e) {
      toastError(e, prefixKey: 'result.couldNotLoadModels');
      return;
    }
    if (!mounted) return;
    final choice = await showDsSheet<({int? modelId, bool random})>(
      context,
      title: tr(context, 'result.renderOn'),
      child: Builder(
        builder: (ctx) {
          final c = ctx.ds.colors;
          final check = Icon(Icons.check, color: c.accent);
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.block),
                title: Text(tr(ctx, 'result.noModelOutfitOnly')),
                trailing: _outfit.modelId == null ? check : null,
                onTap: () => Navigator.pop(ctx, (modelId: null, random: false)),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.casino_outlined),
                title: Text(tr(ctx, 'result.randomModel')),
                subtitle: Text(
                  tr(
                    ctx,
                    models.isNotEmpty
                        ? 'result.randomModelSubHas'
                        : 'result.randomModelSubNone',
                  ),
                ),
                onTap: () => Navigator.pop(ctx, (modelId: null, random: true)),
              ),
              for (final m in models)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.person_outline),
                  title: Text(m.name),
                  trailing: m.id == _outfit.modelId ? check : null,
                  onTap: () =>
                      Navigator.pop(ctx, (modelId: m.id, random: false)),
                ),
            ],
          );
        },
      ),
    );
    if (choice == null || !mounted) return;
    await _runUpdating(
      'result.changeModelFailed',
      () => outfitsServiceOf(context).replaceModel(
        _outfit.id,
        modelId: choice.modelId,
        randomModel: choice.random,
        cancelled: () => !mounted,
      ),
    );
  }

  Future<void> _deleteOutfit() async {
    if (_busy) return;
    final svc = outfitsServiceOf(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(tr(context, 'result.deleteOutfit')),
        content: Text(
          tr(context, 'result.deleteConfirm').replaceFirst(
            '{name}',
            _outfit.modelName ?? tr(context, 'result.outfitFallback'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr(context, 'common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr(context, 'common.delete')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await svc.delete(_outfit.id);
      if (!mounted) return;
      Navigator.pop(context, true); // tell parent to drop from history
      toastKey('result.outfitRemoved');
    } catch (e) {
      toastError(e, prefixKey: 'result.deleteFailed');
    }
  }

  Future<void> _report() async {
    final ok = await _run('result.reportFailed', () async {
      await outfitsServiceOf(context).report(
        _outfit.id,
        message: _outfit.status == 'failed'
            ? 'Generation failed at tier ${_outfit.modelTier}: ${_outfit.error}'
            : 'User reported poor result at tier ${_outfit.modelTier}.',
      );
      return true;
    });
    if (ok == true && mounted) {
      setState(() => _reported = true);
      toastKey('result.reportedThanks');
    }
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final c = ds.colors;
    final muted = ds.typo.label.copyWith(color: c.textMuted);
    final failed = _outfit.status == 'failed';
    // A planned outfit (written by the week planner) carries a day's clothes
    // and no image. Every image action needs one, so they stay hidden until
    // it is rendered.
    final rendered = _outfit.hasRender;
    final hasNext = _outfit.nextTier != null;
    // Null outside the app (widget tests mount the dialog without a session).
    final isAdmin = context.watch<Session?>()?.user?.isAdmin == true;
    final nextTierLabel =
        const {
          'vto': 'Try-On',
          'flex': 'Flex',
          'pro': 'Pro',
          'max': 'Max',
          'openrouter': 'OpenRouter',
          'klein': 'Flex',
          'flux': 'Pro',
        }[_outfit.nextTier] ??
        _outfit.nextTier ??
        '';
    final gap = SizedBox(height: ds.space.s);

    return Dialog(
      insetPadding: EdgeInsets.symmetric(
        horizontal: ds.space.s,
        vertical: ds.space.l,
      ),
      child: SingleChildScrollView(
        padding: EdgeInsets.all(ds.space.m),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    tr(
                      context,
                      rendered
                          ? 'result.generatedOutfit'
                          : 'result.plannedOutfit',
                    ).toUpperCase(),
                    style: ds.typo.headline,
                  ),
                ),
                DsButton.icon(
                  icon: Icons.close,
                  semanticLabel: MaterialLocalizations.of(
                    context,
                  ).closeButtonTooltip,
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            gap,
            Row(
              children: [
                DsBadge(
                  text: _outfit.isManual
                      ? tr(context, 'builder.manual')
                      : _outfit.isMock
                      ? tr(context, 'result.previewBadge')
                      : _outfit.tierLabel,
                ),
                SizedBox(width: ds.space.xs),
                DsBadge(
                  text: tr(
                    context,
                    _outfit.view == 'back' ? 'result.back' : 'result.front',
                  ),
                  tone: _outfit.view == 'back'
                      ? DsBadgeTone.accent
                      : DsBadgeTone.neutral,
                ),
                const Spacer(),
                // Front and back are one linked outfit: flip between them.
                if (_outfit.linkedId != null)
                  DsChip(
                    label: tr(
                      context,
                      _outfit.view == 'back'
                          ? 'result.viewFront'
                          : 'result.viewBack',
                    ),
                    leading: const Icon(Icons.flip, size: 16),
                    selected: false,
                    onTap: _busy ? () {} : _switchLinkedView,
                  ),
              ],
            ),
            gap,
            if (!failed &&
                !_outfit.isPlanned &&
                _outfit.clothIds.isNotEmpty) ...[
              DsSegment<String>(
                options: [
                  ('ai', tr(context, 'result.versionAi')),
                  ('manual', tr(context, 'result.versionManual')),
                ],
                value: _version,
                onChanged: (v) => _switchVersion(v),
              ),
              gap,
            ],
            if (failed)
              _Panel(
                tint: c.danger,
                children: [
                  Text(
                    tr(context, 'result.generationFailed'),
                    style: ds.typo.bodyStrong.copyWith(color: c.danger),
                  ),
                  SizedBox(height: ds.space.xs),
                  Text(tr(context, 'result.outfitKept'), style: muted),
                  if (_outfit.error.isNotEmpty) ...[
                    SizedBox(height: ds.space.xs),
                    Text(
                      _outfit.error,
                      style: ds.typo.monoSmall.copyWith(color: c.danger),
                    ),
                  ],
                  gap,
                  DsButton(
                    label: tr(context, 'result.retryGeneration'),
                    icon: Icons.refresh,
                    expand: true,
                    loading: _busy,
                    onPressed: _busy ? null : _retryGeneration,
                  ),
                ],
              )
            else if (_outfit.isProcessing)
              SizedBox(
                height: 380,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(ds.shape.card),
                  child: OutfitPendingImage(outfit: _outfit),
                ),
              )
            else if (!rendered)
              _Panel(
                children: [
                  if (_pieces.isNotEmpty) ...[
                    OutfitCollage(clothes: _pieces),
                    gap,
                  ],
                  Text(
                    tr(context, 'result.noRenderYet'),
                    textAlign: TextAlign.center,
                    style: muted,
                  ),
                  gap,
                  DsButton(
                    label: tr(context, 'result.generateImage'),
                    icon: Icons.auto_awesome,
                    expand: true,
                    loading: _busy,
                    onPressed: _busy ? null : _regenerate,
                  ),
                ],
              )
            else
              GestureDetector(
                onTap: () =>
                    showOutfitFullscreen(context, outfitImageUrl(_outfit)),
                child: Container(
                  height: 380,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: c.surface,
                    borderRadius: BorderRadius.circular(ds.shape.card),
                  ),
                  // Screen-sized copy through the cache, keyed on the full
                  // URL (it carries ?v=<mtime>) so a same-view re-render
                  // reloads instead of showing the previous image.
                  child: AppImage(
                    url: outfitPreviewUrl(_outfit),
                    cacheKey: outfitPreviewUrl(_outfit),
                    fit: BoxFit.contain,
                    memWidth: 800,
                  ),
                ),
              ),
            if (_outfit.isMock) ...[
              gap,
              Text(
                tr(context, 'result.previewNote'),
                textAlign: TextAlign.center,
                style: muted,
              ),
            ],

            // ----- Pieces: tap to open, cross to drop and re-render -----
            if (_outfit.cloths.isNotEmpty) ...[
              DsSectionTitle(
                tr(context, 'create.clothes'),
                hint: _outfit.algoLabel?.isNotEmpty == true
                    ? '${tr(context, 'result.algorithm')}: ${_outfit.algoLabel}'
                    : null,
              ),
              Wrap(
                spacing: ds.space.xs,
                runSpacing: ds.space.xs,
                children: [
                  for (final cl in _outfit.cloths)
                    _ClothChipWithDelete(
                      name: cl.name,
                      onOpen: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => ClothDetailScreen(clothId: cl.id),
                        ),
                      ),
                      // A montage's pieces change in the builder, not here
                      // (removing one here re-renders the AI picture).
                      onRemove: _busy || _outfit.isManual
                          ? null
                          : () => _removeCloth(cl.id),
                    ),
                ],
              ),
            ],
            gap,
            Wrap(
              spacing: ds.space.xs,
              runSpacing: ds.space.xs,
              children: [
                if (_outfit.cloths.isNotEmpty)
                  _SmallAction(
                    icon: Icons.edit_outlined,
                    label: tr(context, 'result.addSwapClothes'),
                    onTap: _busy
                        ? null
                        : (_outfit.isManual ? _editMontage : _editClothes),
                  ),
                // Swap the person it is rendered on.
                if (!_outfit.isManual)
                  _SmallAction(
                    icon: Icons.person_outline,
                    label: tr(context, 'result.changeModel'),
                    onTap: _busy ? null : _changeModel,
                  ),
                if (_outfit.clothIds.isNotEmpty)
                  _SmallAction(
                    icon: Icons.brush_outlined,
                    label: _outfit.hasManual
                        ? tr(context, 'result.editMontage')
                        : tr(context, 'result.openManual'),
                    onTap: _busy ? null : _editMontage,
                  ),
              ],
            ),

            // ----- Render settings: each change re-renders in place -----
            if (!failed && !_outfit.isManual) ...[
              DsSectionTitle(tr(context, 'create.imageMode')),
              DsSegment<String>(
                options: [
                  ('collage', tr(context, 'create.imageModeCollage')),
                  ('separate', tr(context, 'create.imageModeSeparate')),
                ],
                value: _outfit.imageMode == 'separate' ? 'separate' : 'collage',
                onChanged: (v) {
                  if (!_busy) _setImageMode(v);
                },
              ),
              if (_upperCloths.length >= 2) ...[
                DsSectionTitle(tr(context, 'create.topToRender')),
                Wrap(
                  spacing: ds.space.xs,
                  runSpacing: ds.space.xs,
                  children: [
                    for (final u in _upperCloths)
                      DsChip(
                        label: u.name,
                        selected: _isRendered(u.id),
                        onTap: () {
                          if (!_busy) {
                            _toggleTopRender(u.id, !_isRendered(u.id));
                          }
                        },
                      ),
                  ],
                ),
              ],
              SwitchListTile(
                value: _outfit.describeClothes,
                onChanged: _busy ? null : _toggleDescribe,
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(
                  tr(context, 'create.describeItems'),
                  style: ds.typo.body,
                ),
                subtitle: Text(tr(context, 'result.describeSub'), style: muted),
              ),
            ],
            // The raw prompt sent to the image model is a debugging aid, not
            // something a user reads: admins only, folded away.
            if (!_outfit.isManual && isAdmin)
              Theme(
                data: Theme.of(
                  context,
                ).copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: EdgeInsets.only(bottom: ds.space.s),
                  expandedCrossAxisAlignment: CrossAxisAlignment.start,
                  title: Text(
                    tr(context, 'result.technicalDetails'),
                    style: muted,
                  ),
                  children: [
                    SelectableText(
                      _outfit.prompt.isEmpty
                          ? tr(context, 'result.noTextPrompt')
                          : _outfit.prompt,
                      style: ds.typo.monoSmall.copyWith(color: c.textMuted),
                    ),
                  ],
                ),
              ),
            SizedBox(height: ds.space.m),

            // ----- Image actions -----
            if (!failed && rendered) ...[
              Row(
                children: [
                  Expanded(
                    child: DsButton(
                      label: tr(context, 'result.download'),
                      icon: Icons.download,
                      expand: true,
                      onPressed: _busy
                          ? null
                          : () => saveOutfitImage(
                              context,
                              outfitImageUrl(_outfit),
                            ),
                    ),
                  ),
                  SizedBox(width: ds.space.xs),
                  DsButton.icon(
                    icon: _outfit.isFavorite
                        ? Icons.favorite
                        : Icons.favorite_border,
                    semanticLabel: tr(
                      context,
                      _outfit.isFavorite ? 'result.saved' : 'result.save',
                    ),
                    onPressed: _busy ? null : _toggleFav,
                  ),
                  SizedBox(width: ds.space.xs),
                  DsButton.icon(
                    icon: Icons.ios_share,
                    semanticLabel: tr(context, 'share.action'),
                    onPressed: _busy ? null : _share,
                  ),
                ],
              ),
              gap,
            ],
            if (!failed && !_outfit.isProcessing) ...[
              Row(
                children: [
                  Expanded(
                    child: Text(tr(context, 'result.rate'), style: muted),
                  ),
                  DsRating(score: _outfit.rating, onChanged: _rate),
                ],
              ),
              gap,
            ],
            if (!failed) ...[
              DsButton(
                label: tr(
                  context,
                  _wornToday ? 'result.wornTodayDone' : 'result.markWorn',
                ),
                icon: _wornToday ? Icons.check_circle : Icons.checkroom,
                kind: DsButtonKind.secondary,
                expand: true,
                onPressed: _busy || _wornToday ? null : _markWorn,
              ),
              gap,
            ],
            if (hasNext && rendered) ...[
              DsButton(
                label: tr(context, 'result.tryBetterModel', {
                  'tier': nextTierLabel,
                }),
                icon: Icons.upgrade,
                kind: DsButtonKind.secondary,
                expand: true,
                loading: _busy,
                onPressed: _busy ? null : _regenerate,
              ),
              gap,
            ] else if (!failed && rendered) ...[
              Text(tr(context, 'result.bestModel'), style: muted),
              gap,
            ],

            // ----- Everything else -----
            DsSectionTitle(tr(context, 'result.more')),
            Wrap(
              spacing: ds.space.xs,
              runSpacing: ds.space.xs,
              children: [
                if (!failed)
                  _SmallAction(
                    icon: Icons.history,
                    label: tr(context, 'result.wearHistory'),
                    onTap: _busy ? null : _showWearHistory,
                  ),
                if (!failed &&
                    rendered &&
                    !_outfit.isManual &&
                    _outfit.view == 'front' &&
                    _outfit.linkedId == null)
                  _SmallAction(
                    icon: Icons.flip,
                    label: tr(context, 'result.generateBackView'),
                    onTap: _busy ? null : _generateBack,
                  ),
                if (!failed && rendered) ...[
                  // Re-render with an extra instruction (pose, angle…).
                  if (!_outfit.isManual)
                    _SmallAction(
                      icon: Icons.tune,
                      label: tr(context, 'result.addDetailTitle'),
                      onTap: _busy ? null : _regenerateWithDetail,
                    ),
                  _SmallAction(
                    icon: Icons.event,
                    label: tr(context, 'result.addToAgenda'),
                    onTap: _busy ? null : _addToAgenda,
                  ),
                ],
                // Ban this exact combination from the generator.
                _SmallAction(
                  icon: _outfit.isBlacklisted
                      ? Icons.block_flipped
                      : Icons.block,
                  label: tr(
                    context,
                    _outfit.isBlacklisted
                        ? 'result.bannedTapAllow'
                        : 'result.neverAutoGen',
                  ),
                  onTap: _busy ? null : _toggleBlacklist,
                ),
                _SmallAction(
                  icon: Icons.support_agent,
                  label: tr(
                    context,
                    _reported ? 'result.reportedShort' : 'result.reportProblem',
                  ),
                  onTap: _busy || _reported ? null : _report,
                ),
                _SmallAction(
                  icon: Icons.delete_outline,
                  label: tr(context, 'result.deleteFromHistory'),
                  danger: true,
                  onTap: _busy ? null : _deleteOutfit,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A tinted block inside the dialog (failure, missing render).
class _Panel extends StatelessWidget {
  const _Panel({required this.children, this.tint});

  final List<Widget> children;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Container(
      padding: EdgeInsets.all(ds.space.m),
      decoration: BoxDecoration(
        color: tint?.withValues(alpha: 0.12) ?? ds.colors.surface,
        borderRadius: BorderRadius.circular(ds.shape.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

/// A secondary action as a compact outlined pill: reads as a button, unlike
/// a bare text link, without the weight of a full-width one.
class _SmallAction extends StatelessWidget {
  const _SmallAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final c = ds.colors;
    final fg = onTap == null
        ? c.textMuted
        : danger
        ? c.danger
        : c.text;
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 40),
          padding: EdgeInsets.symmetric(horizontal: ds.space.s),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(ds.shape.pill),
            border: Border.all(color: c.hairline),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: fg),
              SizedBox(width: ds.space.xs),
              Flexible(
                child: Text(label, style: ds.typo.label.copyWith(color: fg)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A garment of the outfit: tap the name to open it, the cross to drop it.
class _ClothChipWithDelete extends StatelessWidget {
  const _ClothChipWithDelete({
    required this.name,
    required this.onOpen,
    required this.onRemove,
  });

  final String name;
  final VoidCallback onOpen;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final c = ds.colors;
    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(ds.shape.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onOpen,
            child: Padding(
              padding: EdgeInsets.only(left: ds.space.s, right: ds.space.xs),
              child: Center(child: Text(name, style: ds.typo.label)),
            ),
          ),
          if (onRemove != null)
            IconButton(
              visualDensity: VisualDensity.compact,
              iconSize: 16,
              tooltip: MaterialLocalizations.of(context).deleteButtonTooltip,
              icon: Icon(Icons.close, color: c.textMuted),
              onPressed: onRemove,
            )
          else
            SizedBox(width: ds.space.s),
        ],
      ),
    );
  }
}
