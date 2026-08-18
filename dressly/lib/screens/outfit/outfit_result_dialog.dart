import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app.dart';
import '../../l10n/app_text.dart';
import '../../models/cloth.dart';
import '../../models/model.dart';
import '../../models/outfit.dart';
import '../../services/outfits_service.dart';
import '../../widgets/outfit_viewer.dart';
import '../cloth/cloth_detail_screen.dart';
import 'cloth_picker_screen.dart';
import '../../widgets/app_image.dart';
import '../../theme/tones.dart';

class OutfitResultDialog extends StatefulWidget {
  const OutfitResultDialog({
    super.key,
    required this.outfit,
    required this.onChanged,
    this.onOpenManual,
  });

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

  @override
  void initState() {
    super.initState();
    _outfit = widget.outfit;
    _wornToday = widget.outfit.wornToday;
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
      _toastKey(errorKey, e);
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// [_run] for the common case: the action yields the updated outfit, which
  /// becomes this dialog's state and is handed to the parent screen.
  Future<Outfit?> _runUpdating(
      String errorKey, Future<Outfit> Function() action) async {
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
  Future<void> _retryGeneration() =>
      _runUpdating('result.retryFailed', () => outfitsServiceOf(context)
          .regenerate(_outfit.id, tier: _outfit.modelTier));

  Future<void> _regenerate() => _runUpdating('result.regenerateFailed',
      () => outfitsServiceOf(context).regenerate(_outfit.id));

  /// Flip "describe items to the AI" and re-render at the same tier.
  Future<void> _toggleDescribe(bool value) =>
      _runUpdating('result.failed', () => outfitsServiceOf(context).regenerate(
          _outfit.id, tier: _outfit.modelTier, describeClothes: value));

  /// Re-render the SAME outfit at its current tier with a changed reference-image
  /// mode and/or top-render subset (the controls that used to live only on the
  /// create screen, now available after generation too).
  Future<void> _reRenderWith({String? imageMode, List<int>? renderClothIds}) =>
      _runUpdating('result.failed', () => outfitsServiceOf(context).regenerate(
          _outfit.id,
          tier: _outfit.modelTier,
          imageMode: imageMode,
          renderClothIds: renderClothIds));

  Future<void> _setImageMode(String mode) async {
    if (mode == _outfit.imageMode) return;
    await _reRenderWith(imageMode: mode);
  }

  /// Upper-body garments in this outfit (base/mid/outer) — the ones the
  /// "which top to render" chooser toggles.
  List<OutfitCloth> get _upperCloths =>
      _outfit.cloths.where((c) => isUpperBody(c.category)).toList()
        ..sort((a, b) => bodyOrder(a.category).compareTo(bodyOrder(b.category)));

  bool _isRendered(int clothId) =>
      _outfit.renderClothIds.isEmpty || _outfit.renderClothIds.contains(clothId);

  Future<void> _toggleTopRender(int clothId, bool render) async {
    final rendered = _outfit.renderClothIds.isEmpty
        ? _outfit.clothIds.toSet()
        : _outfit.renderClothIds.toSet();
    if (render) {
      rendered.add(clothId);
    } else {
      // Keep at least one upper layer visible.
      final visibleUppers =
          _upperCloths.where((c) => rendered.contains(c.id)).length;
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
          content: const Text(
              'A back view renders the person from behind, so it needs one of '
              'your own imported models that has a back photo. The "Random '
              'model" option and generated people can\'t be used for a back '
              'view — choose a specific person you added.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(tr(context, 'result.notNow'))),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(tr(context, 'result.chooseModel'))),
          ],
        ),
      );
      if (go == true && mounted) await _changeModel();
      return;
    }
    final back = await _runUpdating('result.backFailed',
        () => outfitsServiceOf(context).generateBack(_outfit.id));
    if (back != null) _toastKey('result.backCreated');
  }

  Future<void> _switchLinkedView() async {
    if (_outfit.linkedId == null) return;
    // Await completion: editing clothes on one view re-renders the other, so
    // the linked outfit may still be processing when we switch to it.
    await _runUpdating('result.failed',
        () => outfitsServiceOf(context).getAwait(_outfit.linkedId!));
  }

  Future<void> _markWorn() async {
    if (_wornToday) return;
    final ok = await _run('result.failed', () async {
      await outfitsServiceOf(context).wear(_outfit.id);
      return true;
    });
    if (ok == true && mounted) {
      setState(() => _wornToday = true);
      _toastKey('result.markedWorn');
    }
  }

  /// Show every day this outfit was worn + counts (mirrors the per-cloth sheet).
  Future<void> _showWearHistory() async {
    OutfitWears? w;
    try {
      w = await outfitsServiceOf(context).wears(_outfit.id);
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
              Text(
                  'Worn ${wears.total} ${wears.total == 1 ? 'day' : 'days'} '
                  '· ${wears.thisYear} this year',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              if (wears.days.isEmpty)
                Text(tr(context, 'result.notWornYet'),
                    style: TextStyle(color: Colors.grey))
              else
                Flexible(
                  child: SingleChildScrollView(
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children:
                          wears.days.map((d) => Chip(label: Text(d))).toList(),
                    ),
                  ),
                ),
            ],
          ),
        ),
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
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(tr(ctx, 'share.explain')),
            const SizedBox(height: 12),
            SelectableText(shared.url,
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
          ]),
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
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _toggleFav() async {
    final newVal = await _run('result.favoriteFailed', () => outfitsServiceOf(
        context).toggleFavorite(_outfit.id, isFavorite: !_outfit.isFavorite));
    if (newVal == null || !mounted) return;
    setState(() => _outfit = _outfit.copyWith(isFavorite: newVal));
    widget.onChanged(_outfit);
    _toast(newVal ? 'Saved to favorites ✓' : 'Removed from favorites');
  }

  Future<void> _toggleBlacklist() async {
    final newVal = await _run('result.failed', () => outfitsServiceOf(context)
        .setBlacklist(_outfit.id, blacklisted: !_outfit.isBlacklisted));
    if (newVal == null || !mounted) return;
    setState(() => _outfit = _outfit.copyWith(isBlacklisted: newVal));
    widget.onChanged(_outfit);
    _toastKey(newVal ? 'result.bannedToast' : 'result.allowedAgain');
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
              border: const OutlineInputBorder(),
              hintText: tr(context, 'result.addDetailHint'),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(tr(context, 'common.cancel'))),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
                child: Text(tr(context, 'result.regenerate'))),
          ],
        ),
      );
    } finally {
      ctrl.dispose();
    }
    if (detail == null || detail.isEmpty || !mounted) return;
    await _runUpdating('result.regenerateFailed',
        () => outfitsServiceOf(context).regenerate(
            _outfit.id, tier: _outfit.modelTier, addDetail: detail));
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
    final day = '${picked.year.toString().padLeft(4, '0')}-'
        '${picked.month.toString().padLeft(2, '0')}-'
        '${picked.day.toString().padLeft(2, '0')}';
    final ok = await _run('result.agendaFailed', () async {
      await agendaServiceOf(context).create(day: day, outfitId: _outfit.id);
      return true;
    });
    if (ok == true && mounted) {
      _toast('${tr(context, 'result.addedAgenda')} $day ✓');
    }
  }

  Future<void> _removeCloth(int clothId) async {
    if (_busy) return;
    final remaining = _outfit.clothIds.where((id) => id != clothId).toList();
    if (remaining.isEmpty) {
      _toastKey('result.needOneCloth');
      return;
    }
    await _runUpdating('result.removeFailed', () => outfitsServiceOf(context)
        .replaceClothes(_outfit.id, remaining));
  }

  Future<void> _editClothes() async {
    if (_busy) return;
    final svc = outfitsServiceOf(context);
    final picked = await Navigator.push<Set<int>>(
      context,
      MaterialPageRoute(
        builder: (_) => ClothPickerScreen(
          initialSelected: _outfit.clothIds.toSet(),
        ),
      ),
    );
    if (picked == null || picked.isEmpty) return;
    await _runUpdating('result.regenerateFailed',
        () => svc.replaceClothes(_outfit.id, picked.toList()));
  }

  /// Swap the person the outfit is rendered on (or drop the model) and
  /// re-render — the counterpart to "Add / swap clothes".
  Future<void> _changeModel() async {
    if (_busy) return;
    List<ModelEntity> models;
    try {
      models = await modelsServiceOf(context).list();
    } catch (e) {
      _toastKey('result.couldNotLoadModels', e);
      return;
    }
    if (!mounted) return;
    final choice = await showModalBottomSheet<({int? modelId, bool random})>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.all(14),
            child: Text(tr(context, 'result.renderOn'),
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ),
          ListTile(
            leading: const Icon(Icons.block),
            title: Text(tr(context, 'result.noModelOutfitOnly')),
            trailing: _outfit.modelId == null
                ? const Icon(Icons.check, color: Colors.tealAccent)
                : null,
            onTap: () => Navigator.pop(ctx, (modelId: null, random: false)),
          ),
          ListTile(
            leading: const Icon(Icons.casino),
            title: Text(tr(context, 'result.randomModel')),
            subtitle: Text(models.isNotEmpty
                ? tr(context, 'result.randomModelSubHas')
                : tr(context, 'result.randomModelSubNone')),
            onTap: () => Navigator.pop(ctx, (modelId: null, random: true)),
          ),
          for (final m in models)
            ListTile(
              leading: const Icon(Icons.person),
              title: Text(m.name),
              trailing: m.id == _outfit.modelId
                  ? const Icon(Icons.check, color: Colors.tealAccent)
                  : null,
              onTap: () => Navigator.pop(ctx, (modelId: m.id, random: false)),
            ),
        ]),
      ),
    );
    if (choice == null || !mounted) return;
    await _runUpdating('result.changeModelFailed',
        () => outfitsServiceOf(context).replaceModel(
              _outfit.id,
              modelId: choice.modelId,
              randomModel: choice.random,
            ));
  }

  Future<void> _deleteOutfit() async {
    if (_busy) return;
    final svc = outfitsServiceOf(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(tr(context, 'result.deleteOutfit')),
        content: Text(tr(context, 'result.deleteConfirm').replaceFirst(
            '{name}', _outfit.modelName ?? tr(context, 'result.outfitFallback'))),
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
    if (confirmed != true) return;
    try {
      await svc.delete(_outfit.id);
      if (!mounted) return;
      Navigator.pop(context, true);  // tell parent to drop from history
      _toastKey('result.outfitRemoved');
    } catch (e) {
      _toastKey('result.deleteFailed', e);
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
      _toastKey('result.reportedThanks');
    }
  }

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  void _toastKey(String key, [Object? err]) {
    if (!mounted) return;
    final msg = tr(context, key);
    _toast(err == null ? msg : '$msg: $err');
  }

  @override
  Widget build(BuildContext context) {
    final failed = _outfit.status == 'failed';
    final hasNext = _outfit.nextTier != null;
    final nextTierLabel = const {
      'vto': 'Try-On',
      'flex': 'Flex',
      'pro': 'Pro',
      'max': 'Max',
      'klein': 'Flex',
      'flux': 'Pro',
    }[_outfit.nextTier] ??
        _outfit.nextTier ??
        '';
    return Dialog(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Text(tr(context, 'result.generatedOutfit'),
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const Spacer(),
            IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context)),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: subtleFill(context),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                _outfit.isMock
                    ? tr(context, 'result.previewBadge')
                    : _outfit.tierLabel,
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: _outfit.view == 'back' ? Colors.indigo : Colors.teal,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                _outfit.view == 'back' ? tr(context, 'result.back') : tr(context, 'result.front'),
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
              ),
            ),
            if (_outfit.linkedId != null) ...[
              const Spacer(),
              // Front and back are one linked outfit — toggle between them.
              TextButton.icon(
                onPressed: _busy ? null : _switchLinkedView,
                icon: const Icon(Icons.flip, size: 16),
                label: Text(_outfit.view == 'back' ? tr(context, 'result.viewFront') : tr(context, 'result.viewBack')),
              ),
            ],
          ]),
          const SizedBox(height: 8),
          if (failed)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr(context, 'result.generationFailed'),
                    style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(tr(context, 'result.outfitKept'),
                    style: TextStyle(
                        color: secondaryText(context), fontSize: 12)),
                if (_outfit.error.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(_outfit.error,
                      style: const TextStyle(color: Colors.redAccent, fontSize: 11)),
                ],
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _retryGeneration,
                    icon: _busy
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.refresh),
                    label: Text(tr(context, 'result.retryGeneration')),
                  ),
                ),
              ]),
            )
          else
            GestureDetector(
              onTap: () => showOutfitFullscreen(context, outfitImageUrl(_outfit)),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                // Screen-sized copy, through the cache. The stored render was
                // re-fetched in full on every rebuild of this dialog, and it
                // rebuilds on every action taken in it.
                child: SizedBox(
                  height: 360,
                  child: AppImage(
                    url: outfitPreviewUrl(_outfit),
                    // Keyed on the full URL (which carries ?v=<mtime>) so a
                    // same-view regenerate — e.g. changing the model — reloads
                    // instead of showing the previous render.
                    cacheKey: outfitPreviewUrl(_outfit),
                    fit: BoxFit.contain,
                    memWidth: 800,
                  ),
                ),
              ),
            ),
          const SizedBox(height: 8),
          if (_outfit.isMock)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                    color: Colors.amber.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(8)),
                child: Text(
                    tr(context, 'result.previewNote'),
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.amber, fontSize: 12)),
              ),
            ),
          // Algorithm label only. The clothes themselves are shown once, as the
          // editable chips just below (tap = open, ✕ = remove) — no duplicate
          // green list above them.
          if (_outfit.algoLabel != null && _outfit.algoLabel!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text('${tr(context, 'result.algorithm')}: ${_outfit.algoLabel}',
                  style: const TextStyle(
                      color: Colors.tealAccent,
                      fontSize: 12,
                      fontWeight: FontWeight.bold)),
            ),
          // Editable cloth chips — tap the name to open the cloth's detail
          // screen (see all info + edit), tap ✕ to drop it and re-render. Tap
          // is implemented on a custom widget so it doesn't fight the
          // delete button.
          if (_outfit.cloths.isNotEmpty) ...[
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: _outfit.cloths
                  .map((c) => _ClothChipWithDelete(
                        clothId: c.id,
                        name: c.name,
                        onOpen: () {
                          Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => ClothDetailScreen(clothId: c.id),
                          ));
                        },
                        onRemove: _busy ? null : () => _removeCloth(c.id),
                      ))
                  .toList(),
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _busy ? null : _editClothes,
                icon: const Icon(Icons.edit_outlined),
                label: Text(tr(context, 'result.addSwapClothes')),
              ),
            ),
          ],
          // Swap the person the outfit is rendered on (mirror of "swap clothes").
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _busy ? null : _changeModel,
              icon: const Icon(Icons.person_outline),
              label: Text(_outfit.modelName == null
                  ? tr(context, 'result.changeModel')
                  : '${tr(context, 'result.changeModel')} (${_outfit.modelName})'),
            ),
          ),
          // Open this outfit's clothes in the non-AI manual builder.
          if (widget.onOpenManual != null && _outfit.clothIds.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _busy
                    ? null
                    : () {
                        final o = _outfit;
                        Navigator.of(context).pop();
                        widget.onOpenManual!(o);
                      },
                icon: const Icon(Icons.brush_outlined),
                label: Text(trOr(context, 'result.openManual',
                    'Edit in manual builder')),
              ),
            ),
          // Toggle the item description in the prompt, then re-render in place.
          if (!failed)
            SwitchListTile(
              value: _outfit.describeClothes,
              onChanged: _busy ? null : _toggleDescribe,
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(tr(context, 'create.describeItems')),
              subtitle: Text(
                  tr(context, 'result.describeSub'),
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ),
          // Reference-image mode — re-renders in place when changed.
          if (!failed) ...[
            const SizedBox(height: 4),
            Text(tr(context, 'create.imageMode'),
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            SegmentedButton<String>(
              showSelectedIcon: false,
              style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 12))),
              segments: [
                ButtonSegment(
                    value: 'collage',
                    label: Text(tr(context, 'create.imageModeCollage'))),
                ButtonSegment(
                    value: 'separate',
                    label: Text(tr(context, 'create.imageModeSeparate'))),
              ],
              selected: {_outfit.imageMode == 'separate' ? 'separate' : 'collage'},
              onSelectionChanged:
                  _busy ? null : (s) => _setImageMode(s.first),
            ),
          ],
          // Which top to render — only when the outfit has several upper layers.
          if (!failed && _upperCloths.length >= 2) ...[
            const SizedBox(height: 8),
            Text(tr(context, 'create.topToRender'),
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
            for (final c in _upperCloths)
              CheckboxListTile(
                value: _isRendered(c.id),
                onChanged: _busy
                    ? null
                    : (v) => _toggleTopRender(c.id, v ?? true),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                dense: true,
                title: Text(c.name),
                subtitle: Text(categoryName(context, c.category),
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ),
          ],
          Text(_outfit.prompt.isEmpty
              ? tr(context, 'result.noTextPrompt')
              : _outfit.prompt,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: secondaryText(context), fontSize: 12)),
          const SizedBox(height: 12),
          // Image actions: download, favorite.
          if (!failed)
            Row(children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy ? null : () => saveOutfitImage(context, outfitImageUrl(_outfit)),
                  icon: const Icon(Icons.download),
                  label: Text(tr(context, 'result.download')),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _toggleFav,
                  icon: Icon(_outfit.isFavorite
                      ? Icons.favorite
                      : Icons.favorite_border),
                  label: Text(_outfit.isFavorite ? 'Saved' : 'Save'),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: _busy ? null : _share,
                icon: const Icon(Icons.ios_share),
                tooltip: tr(context, 'share.action'),
              ),
            ]),
          if (!failed) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: _wornToday
                  ? FilledButton.icon(
                      onPressed: null,
                      style: FilledButton.styleFrom(
                          disabledBackgroundColor: Colors.teal.shade700,
                          disabledForegroundColor: Colors.white),
                      icon: const Icon(Icons.check_circle),
                      label: Text(tr(context, 'result.wornTodayDone')),
                    )
                  : OutlinedButton.icon(
                      onPressed: _busy ? null : _markWorn,
                      icon: const Icon(Icons.checkroom),
                      label: Text(tr(context, 'result.markWorn')),
                    ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _busy ? null : _showWearHistory,
                icon: const Icon(Icons.history, size: 18),
                label: Text(tr(context, 'result.wearHistory')),
              ),
            ),
          ],
          const SizedBox(height: 8),
          // Cascade + back-view actions.
          if (hasNext)
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _busy ? null : _regenerate,
                icon: _busy
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.upgrade),
                label: Text('${tr(context, 'result.tryBetterModel')} ($nextTierLabel)'),
              ),
            )
          else if (!failed)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(tr(context, 'result.bestModel'),
                  style: const TextStyle(color: Colors.white54, fontSize: 12)),
            ),
          if (!failed && _outfit.view == 'front' &&
              _outfit.linkedId == null) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _generateBack,
                icon: _busy
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.flip),
                label: Text(tr(context, 'result.generateBackView')),
              ),
            ),
          ],
          if (!failed) ...[
            const SizedBox(height: 8),
            // Re-render with an extra instruction (pose, angle, setting…).
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _regenerateWithDetail,
                icon: const Icon(Icons.tune),
                label: Text(tr(context, 'result.addDetailTitle')),
              ),
            ),
            const SizedBox(height: 8),
            // Plan this outfit for a day.
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _addToAgenda,
                icon: const Icon(Icons.event),
                label: Text(tr(context, 'result.addToAgenda')),
              ),
            ),
          ],
          const SizedBox(height: 8),
          // Ban this exact cloth combination from the generator.
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _busy ? null : _toggleBlacklist,
              icon: Icon(_outfit.isBlacklisted
                  ? Icons.block_flipped
                  : Icons.block),
              label: Text(_outfit.isBlacklisted
                  ? tr(context, 'result.bannedTapAllow')
                  : tr(context, 'result.neverAutoGen')),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _busy || _reported ? null : _report,
              icon: const Icon(Icons.support_agent),
              label: Text(_reported ? tr(context, 'result.reportedShort') : tr(context, 'result.reportProblem')),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _busy ? null : _deleteOutfit,
              icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
              label: Text(tr(context, 'result.deleteFromHistory'),
                  style: const TextStyle(color: Colors.redAccent)),
            ),
          ),
        ]),
      ),
    );
  }
}


/// Dialog that shows the algorithm's proposed selections (cloth picks only, no
/// image) and asks the user to confirm before any outfit is rendered. Supports
/// "Reshuffle" (re-run the algorithm for fresh picks) and "Generate" (render
/// every selection in parallel).

class _ClothChipWithDelete extends StatelessWidget {
  const _ClothChipWithDelete({
    required this.clothId,
    required this.name,
    required this.onOpen,
    required this.onRemove,
  });
  final int clothId;
  final String name;
  final VoidCallback onOpen;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white12,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white24),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        InkWell(
          onTap: onOpen,
          borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(16), bottomLeft: Radius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
            child: Text(name, style: const TextStyle(fontSize: 12)),
          ),
        ),
        if (onRemove != null)
          InkWell(
            onTap: onRemove,
            borderRadius: const BorderRadius.only(
                topRight: Radius.circular(16),
                bottomRight: Radius.circular(16)),
            child: const Padding(
              padding: EdgeInsets.fromLTRB(4, 6, 8, 6),
              child: Icon(Icons.close, size: 16, color: Colors.white70),
            ),
          ),
      ]),
    );
  }
}

