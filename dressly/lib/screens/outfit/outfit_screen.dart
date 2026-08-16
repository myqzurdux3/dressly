import 'package:flutter/material.dart';

import '../../app.dart';
import '../../config/api_config.dart';
import '../../l10n/app_text.dart';
import '../../models/cloth.dart';
import '../../models/model.dart';
import '../../models/outfit.dart';
import '../../services/outfits_service.dart';
import '../../state/paged_list.dart';
import '../../widgets/outfit_history_card.dart';
import '../../widgets/model_chip.dart';
import '../../widgets/section_header.dart';
import '../../widgets/outfit_sort_sheet.dart';
import '../models/add_model_screen.dart';
import '../models/models_screen.dart';
import 'cloth_picker_screen.dart';
import 'algo_preview_dialog.dart';
import 'algo_sheet.dart';
import 'manual_builder_screen.dart';
import 'outfit_result_dialog.dart';
import '../../widgets/app_image.dart';

class OutfitScreen extends StatefulWidget {
  const OutfitScreen({super.key});

  @override
  State<OutfitScreen> createState() => _OutfitScreenState();
}

class _OutfitScreenState extends State<OutfitScreen> {
  List<ModelEntity> _models = [];
  ModelEntity? _selectedModel; // null with models present = explicit "no model"
  // When true, the server picks a random model for each generation (so a
  // batch of random outfits can show different people).
  bool _randomModel = false;
  String _randomGender = ''; // '' any | 'male' | 'female' (for random model)
  bool _describeClothes = false;
  String _imageMode = 'collage'; // 'collage' = one reference image | 'separate'
  // Upper-body garments the user chose NOT to render (when several tops/layers
  // are selected, so the AI shows one top instead of stacking them).
  final Set<int> _hiddenTopIds = {};
  List<Cloth> _clothes = [];
  final Set<int> _selectedClothIds = {};
  final _prompt = TextEditingController();
  late final PagedList<Outfit> _history;
  OutfitQuery _outfitQuery = const OutfitQuery();
  bool _generating = false;
  String _mode = 'ai'; // 'ai' = AI generation | 'manual' = non-AI builder

  @override
  void initState() {
    super.initState();
    _history = PagedList<Outfit>(
      // Query read at call time, so changing it and refreshing is enough.
      fetchPage: ({required limit, required offset}) => outfitsServiceOf(context)
          .list(
              sort: _outfitQuery.sort,
              favorite: _outfitQuery.favorite,
              model: _outfitQuery.model,
              limit: limit,
              offset: offset),
    );
    _loadAll();
  }

  @override
  void dispose() {
    _history.dispose();
    _prompt.dispose();
    super.dispose();
  }

  Future<void> _loadAll() async {
    // Resolve services before the first await so we never touch `context`
    // across an async gap.
    final modelsSvc = modelsServiceOf(context);
    final clothesSvc = clothesServiceOf(context);
    try {
      // Two independent requests: awaited one after the other they cost two
      // round trips before the screen can draw anything.
      final results = await Future.wait([modelsSvc.list(), clothesSvc.list()]);
      final models = results[0] as List<ModelEntity>;
      final clothes = results[1] as List<Cloth>;
      if (!mounted) return;
      setState(() {
        _models = models;
        _clothes = clothes;
      });
      await _history.refresh();
    } catch (e) {
      if (mounted) _toastKey('result.loadFailed', e);
    }
  }

  Future<void> _openHistorySort() async {
    final result = await showOutfitSortSheet(context, _outfitQuery);
    if (result == null || !mounted) return;
    setState(() => _outfitQuery = result);
    await _history.refresh();
    if (mounted && _history.error != null) {
      _toastKey('result.loadFailed', _history.error);
    }
  }

  Future<void> _generate() async {
    if (_selectedClothIds.isEmpty) {
      _toastKey('result.pickAtLeastOne');
      return;
    }
    setState(() => _generating = true);
    try {
      final outfit = await outfitsServiceOf(context).generate(
        modelId: _selectedModel?.id,
        randomModel: _randomModel,
        randomModelGender: _randomModel ? _randomGender : '',
        clothIds: _selectedClothIds.toList(),
        prompt: _prompt.text.trim(),
        describeClothes: _describeClothes,
        tier: genPrefsOf(context).startTier,
        imageMode: _imageMode,
        renderClothIds: _renderClothIds,
      );
      _history.prepend(outfit);
      _showResult(outfit);
    } catch (e) {
      _toastKey('result.generationFailed', e);
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  void _showResult(Outfit outfit) async {
    final deleted = await showDialog<bool>(
      context: context,
      builder: (_) => OutfitResultDialog(
        outfit: outfit,
        // Convert AI -> manual by editing the SAME outfit in place (no dup).
        onOpenManual: (o) => _openBuilder(existing: o),
        onChanged: (updated) {
          // Back views belong to their front — they must NOT show as a
          // separate history entry. Just link the front to it (so the front's
          // front/back toggle keeps working) and drop any stray copy.
          if (updated.view == 'back') {
            if (updated.linkedId != null) {
              final front = _history.items
                  .where((o) => o.id == updated.linkedId)
                  .firstOrNull;
              if (front != null) {
                _history.replaceItem((o) => o.id == front.id,
                    front.withLinkedId(updated.id));
              }
            }
            _history.removeItem((o) => o.id == updated.id);
            return;
          }
          if (_history.items.any((o) => o.id == updated.id)) {
            _history.replaceItem((o) => o.id == updated.id, updated);
          } else {
            _history.prepend(updated);
          }
        },
      ),
    );
    if (deleted == true) {
      _history.removeItem((o) => o.id == outfit.id);
    }
  }

  Future<void> _openAlgoSheet() async {
    final result = await showModalBottomSheet<AlgoPick>(
      context: context,
      isScrollControlled: true,
      builder: (_) => AlgoSheet(clothes: _clothes),
    );
    if (result == null) return;
    await _showAlgoPreview(result);
  }

  /// The "Manual builder" tab header: explains the non-AI mode and opens the
  /// canvas. Saved manual outfits show up in the shared history below.
  Widget _buildManualSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(trOr(context, 'builder.title', 'Manual builder')),
        const SizedBox(height: 4),
        Text(trOr(context, 'builder.intro',
            'Arrange your clothes on a background you choose. No AI — you '
            'place, move and resize each item yourself.'),
            style: const TextStyle(color: Colors.grey, fontSize: 12)),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          height: 56,
          child: FilledButton.icon(
            onPressed: () => _openBuilder(),
            icon: const Icon(Icons.brush),
            label: Text(trOr(context, 'builder.new', 'New manual outfit'),
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ),
        ),
      ],
    );
  }

  /// Open the non-AI builder (fresh, editing an existing manual outfit, or
  /// seeded with cloth ids). Folds a saved manual outfit into history, or — if
  /// the user chose "Generate with AI" — hands its clothes to AI mode.
  Future<void> _openBuilder({Outfit? existing, List<int>? initialClothIds}) async {
    final res = await Navigator.push<ManualBuilderResult>(
      context,
      MaterialPageRoute(
        builder: (_) => ManualBuilderScreen(
            existing: existing, initialClothIds: initialClothIds),
      ),
    );
    if (res == null || !mounted) return;
    if (res.toAiClothIds != null) {
      _switchToAiWith(res.toAiClothIds!);
      return;
    }
    final saved = res.saved;
    if (saved == null) return;
    if (_history.items.any((o) => o.id == saved.id)) {
      _history.replaceItem((o) => o.id == saved.id, saved);
    } else {
      _history.prepend(saved);
    }
  }

  /// Move an outfit's clothes into AI mode: switch the toggle, select exactly
  /// those clothes, and scroll to the top so the user can pick a model + render.
  void _switchToAiWith(List<int> clothIds) {
    setState(() {
      _mode = 'ai';
      _selectedClothIds
        ..clear()
        ..addAll(clothIds);
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(trOr(context, 'builder.movedToAi',
            'Clothes loaded in AI mode — pick a model and generate'))));
  }

  Future<void> _showAlgoPreview(AlgoPick pick) async {
    // The model, "describe items" and extra prompt come from the SAME controls
    // as manual generation. Any clothes the user picked are locked in — the
    // algorithm fills the rest around them.
    final locked = _selectedClothIds.toList();
    // 1. Run the algorithm WITHOUT generating images, get the proposed picks.
    AlgoPreview preview;
    try {
      preview = await outfitsServiceOf(context).previewAlgo(
        algo: pick.algo,
        minScore: pick.minScore,
        color: pick.color,
        brand: pick.brand,
        tag: pick.tag,
        count: pick.count,
        weather: pick.weather,
        categories: pick.categories,
        lockedClothIds: locked,
        fillGaps: pick.fillGaps,
      );
    } catch (e) {
      _toastKey('result.selectionFailed', e);
      return;
    }
    if (!mounted) return;

    // 2. Let the user confirm / reshuffle before rendering anything.
    final confirmed = await showDialog<AlgoPreview>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlgoPreviewDialog(
        pick: pick,
        initial: preview,
        onReshuffle: () => outfitsServiceOf(context).previewAlgo(
          algo: pick.algo,
          minScore: pick.minScore,
          color: pick.color,
          brand: pick.brand,
          tag: pick.tag,
          count: pick.count,
          weather: pick.weather,
          categories: pick.categories,
          lockedClothIds: locked,
          fillGaps: pick.fillGaps,
        ),
      ),
    );
    if (confirmed == null || confirmed.selections.isEmpty) return;
    if (!mounted) return;

    // 3. Render the confirmed selections concurrently so the user gets several
    //    outfits at once instead of waiting per outfit. Each lands in history
    //    as soon as it resolves; the first opens in the result dialog.
    setState(() => _generating = true);
    final tier = genPrefsOf(context).startTier;
    final imageMode = _imageMode;
    final svc = outfitsServiceOf(context);
    final outfits = <Outfit>[];
    final futures = confirmed.selections.map((sel) {
      final clothIds = sel.map((c) => c.id).toList();
      return svc
          .generate(
            modelId: _selectedModel?.id,
            randomModel: _randomModel,
            randomModelGender: _randomModel ? _randomGender : '',
            clothIds: clothIds,
            prompt: _prompt.text.trim(),
            describeClothes: _describeClothes,
            tier: tier,
            imageMode: imageMode,
          )
          .then((o) {
            outfits.add(o);
            if (mounted) _history.prepend(o);
            return o;
          });
    }).toList();
    try {
      await Future.wait(futures);
    } catch (e) {
      _toastKey('result.someFailed', e);
    } finally {
      if (mounted) setState(() => _generating = false);
    }
    if (outfits.isNotEmpty && mounted) {
      outfits.sort((a, b) => b.id.compareTo(a.id));
      _showResult(outfits.first);
    }
  }

  Cloth? _clothesById(int id) {
    for (final c in _clothes) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// Selected upper-body garments (base top, mid layer, outer), head-to-toe.
  List<Cloth> get _selectedUppers {
    final out = <Cloth>[];
    for (final id in _selectedClothIds) {
      final c = _clothesById(id);
      if (c != null && isUpperBody(c.category)) out.add(c);
    }
    out.sort((a, b) => bodyOrder(a.category).compareTo(bodyOrder(b.category)));
    return out;
  }

  /// The clothes to actually render: empty = render everything; otherwise the
  /// selection minus the upper garments the user hid via the "top to render"
  /// chooser (so one top shows, not a messy stack of three).
  List<int> get _renderClothIds {
    final hidden = _hiddenTopIds.where(_selectedClothIds.contains).toSet();
    if (hidden.isEmpty) return const [];
    return _selectedClothIds.where((id) => !hidden.contains(id)).toList();
  }

  void _toast(String m) {
    if (!mounted) return; // the screen may be gone by the time an async op ends
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  void _toastKey(String key, [Object? err]) {
    if (!mounted) return;
    final msg = tr(context, key);
    _toast(err == null ? msg : '$msg: $err');
  }

  Future<void> _deleteOutfit(Outfit o) async {
    try {
      await outfitsServiceOf(context).delete(o.id);
      _history.removeItem((x) => x.id == o.id);
    } catch (e) {
      _toastKey('result.deleteFailed', e);
    }
  }

  Future<void> _confirmDeleteOutfit(Outfit o) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(tr(context, 'create.deleteTitle')),
        content: Text(tr(context, 'create.deleteConfirm')),
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
    if (ok == true) _deleteOutfit(o);
  }

  Future<void> _toggleFavorite(Outfit o) async {
    try {
      final newVal = await outfitsServiceOf(context)
          .toggleFavorite(o.id, isFavorite: !o.isFavorite);
      _history.replaceItem((x) => x.id == o.id, _replaceFavorite(o, newVal));
    } catch (e) {
      _toastKey('result.favoriteFailed', e);
    }
  }

  Outfit _replaceFavorite(Outfit o, bool fav) => Outfit(
        id: o.id, modelId: o.modelId, modelName: o.modelName,
        clothIds: o.clothIds, cloths: o.cloths, prompt: o.prompt,
        generatedUrl: o.generatedUrl, status: o.status, isMock: o.isMock,
        modelTier: o.modelTier, modelSlug: o.modelSlug, view: o.view,
        linkedId: o.linkedId, wornToday: o.wornToday,
        isFavorite: fav, nextTier: o.nextTier,
        describeClothes: o.describeClothes, isBlacklisted: o.isBlacklisted,
        imageMode: o.imageMode, renderClothIds: o.renderClothIds,
        error: o.error,
        createdAt: o.createdAt,
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'create.title'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        // ----- AI vs manual (non-AI) builder toggle -----
        Center(
          child: SegmentedButton<String>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                  value: 'ai',
                  icon: const Icon(Icons.auto_awesome, size: 18),
                  label: Text(trOr(context, 'builder.ai', 'AI'))),
              ButtonSegment(
                  value: 'manual',
                  icon: const Icon(Icons.brush, size: 18),
                  label: Text(trOr(context, 'builder.manual', 'Manual'))),
            ],
            selected: {_mode},
            onSelectionChanged: (s) => setState(() => _mode = s.first),
          ),
        ),
        const SizedBox(height: 16),
        if (_mode == 'manual') ...[
          _buildManualSection(),
          const SizedBox(height: 24),
        ],
        if (_mode == 'ai') ...[
          // ----- Model picker -----
          SectionHeader(tr(context, 'create.modelSection')),
          const SizedBox(height: 4),
          Text(tr(context, 'create.modelHint'),
              style: const TextStyle(color: Colors.grey, fontSize: 12)),
        const SizedBox(height: 8),
        SizedBox(
          height: 130,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              // "No model" chip — generates outfit without a person.
              ModelChip(
                label: tr(context, 'create.noModel'),
                icon: Icons.person_off,
                selected: _selectedModel == null && !_randomModel,
                onTap: () => setState(() {
                  _selectedModel = null;
                  _randomModel = false;
                }),
              ),
              const SizedBox(width: 10),
              // "Random model" — server picks one of your models per outfit.
              ModelChip(
                label: tr(context, 'create.randomModel'),
                icon: Icons.shuffle,
                selected: _randomModel,
                onTap: () => setState(() {
                  _randomModel = true;
                  _selectedModel = null;
                }),
              ),
              for (final m in _models) ...[
                const SizedBox(width: 10),
                ModelChip(
                  label: m.name,
                  thumbUrl: m.thumbImageUrl,
                  selected: _selectedModel?.id == m.id && !_randomModel,
                  onTap: () => setState(() {
                    _randomModel = false;
                    _selectedModel =
                        _selectedModel?.id == m.id ? null : m;
                  }),
                ),
              ],
              // No models yet? Offer a direct "Add model" shortcut.
              if (_models.isEmpty) ...[
                const SizedBox(width: 10),
                ModelChip(
                  label: tr(context, 'create.addModel'),
                  icon: Icons.person_add,
                  selected: false,
                  onTap: () async {
                    await Navigator.push(context,
                        MaterialPageRoute(builder: (_) => const AddModelScreen()));
                    _loadAll();
                  },
                ),
              ],
              // Manage models lives right next to the pickers (add / edit /
              // delete people), so it's where you look when choosing a model.
              const SizedBox(width: 10),
              ModelChip(
                label: tr(context, 'create.manage'),
                icon: Icons.tune,
                selected: false,
                onTap: () async {
                  await Navigator.push(context,
                      MaterialPageRoute(builder: (_) => const ModelsScreen()));
                  _loadAll();
                },
              ),
            ],
          ),
        ),
        // Male/female filter for the random model pick.
        if (_randomModel) ...[
          const SizedBox(height: 12),
          Row(children: [
            Text(tr(context, 'create.randomGender'),
                style: const TextStyle(fontSize: 13)),
            const SizedBox(width: 12),
            Expanded(
              child: SegmentedButton<String>(
                showSelectedIcon: false,
                style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    textStyle:
                        WidgetStatePropertyAll(TextStyle(fontSize: 12))),
                segments: [
                  ButtonSegment(
                      value: '', label: Text(tr(context, 'create.genderAny'))),
                  ButtonSegment(
                      value: 'male',
                      label: Text(tr(context, 'create.genderMale'))),
                  ButtonSegment(
                      value: 'female',
                      label: Text(tr(context, 'create.genderFemale'))),
                ],
                selected: {_randomGender},
                onSelectionChanged: (s) =>
                    setState(() => _randomGender = s.first),
              ),
            ),
          ]),
        ],
        const SizedBox(height: 24),

        // ----- Clothes picker -----
        SectionHeader('${tr(context, 'create.clothes')} '
            '(${_selectedClothIds.length} ${tr(context, 'create.selected')})'),
        const SizedBox(height: 8),
        if (_clothes.isEmpty)
          Text(tr(context, 'create.noClothes'),
              style: const TextStyle(color: Colors.grey))
        else
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () async {
                    final picked = await Navigator.push<Set<int>>(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ClothPickerScreen(
                          initialSelected: _selectedClothIds,
                        ),
                      ),
                    );
                    if (picked != null && mounted) {
                      setState(() => _selectedClothIds
                        ..clear()
                        ..addAll(picked));
                    }
                  },
                  icon: const Icon(Icons.checklist),
                  label: Text(_selectedClothIds.isEmpty
                      ? tr(context, 'create.pickClothes')
                      : '${tr(context, 'create.editSelection')} (${_selectedClothIds.length})'),
                ),
              ),
            ]),
            if (_selectedClothIds.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: _selectedClothIds.map((id) {
                  final c = _clothesById(id);
                  return InputChip(
                    label: Text(c?.name ?? '#$id'),
                    // A ~40 px avatar: the thumbnail, through the cache. This
                    // used to pull the full lossless cut-out (~756 KB) with no
                    // disk copy, once per selected cloth.
                    avatar: c?.thumbImageUrl == null
                        ? null
                        : CircleAvatar(
                            backgroundColor: Colors.blueGrey.shade900,
                            backgroundImage:
                                appImageProvider(imageUrl(c!.thumbImageUrl!)),
                          ),
                    onDeleted: () =>
                        setState(() => _selectedClothIds.remove(id)),
                  );
                }).toList(),
              ),
            ],
          ]),
        const SizedBox(height: 24),

        // ----- Which top to render (only when several upper layers chosen) -----
        if (_selectedUppers.length >= 2) ...[
          SectionHeader(tr(context, 'create.topToRender')),
          const SizedBox(height: 4),
          Text(tr(context, 'create.topToRenderHint'),
              style: const TextStyle(color: Colors.grey, fontSize: 12)),
          for (final c in _selectedUppers)
            CheckboxListTile(
              value: !_hiddenTopIds.contains(c.id),
              onChanged: (v) => setState(() {
                if (v == false) {
                  final visible = _selectedUppers
                      .where((u) => !_hiddenTopIds.contains(u.id))
                      .length;
                  if (visible <= 1) return; // keep at least one top visible
                  _hiddenTopIds.add(c.id);
                } else {
                  _hiddenTopIds.remove(c.id);
                }
              }),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              dense: true,
              title: Text(c.name),
              subtitle: Text(categoryName(context, c.category),
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ),
          const SizedBox(height: 24),
        ],

        // ----- Image mode: one combined reference vs one image per garment -----
        SectionHeader(tr(context, 'create.imageMode')),
        const SizedBox(height: 4),
        Text(tr(context, 'create.imageModeHint'),
            style: const TextStyle(color: Colors.grey, fontSize: 12)),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          showSelectedIcon: false,
          segments: [
            ButtonSegment(
                value: 'collage',
                icon: const Icon(Icons.grid_view, size: 18),
                label: Text(tr(context, 'create.imageModeCollage'))),
            ButtonSegment(
                value: 'separate',
                icon: const Icon(Icons.collections, size: 18),
                label: Text(tr(context, 'create.imageModeSeparate'))),
          ],
          selected: {_imageMode},
          onSelectionChanged: (s) => setState(() => _imageMode = s.first),
        ),
        const SizedBox(height: 24),

        // ----- Optional prompt -----
        SectionHeader(tr(context, 'create.extraPrompt')),
        const SizedBox(height: 4),
        Text(tr(context, 'create.promptDesc'),
            style: const TextStyle(color: Colors.grey, fontSize: 12)),
        const SizedBox(height: 8),
        TextField(
          controller: _prompt,
          maxLines: 2,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            hintText: tr(context, 'create.promptHint'),
          ),
        ),
        const SizedBox(height: 4),
        CheckboxListTile(
          value: _describeClothes,
          onChanged: (v) => setState(() => _describeClothes = v ?? false),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          dense: true,
          title: Text(tr(context, 'create.describeItems')),
          subtitle: Text(tr(context, 'create.describeSub'),
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ),
        const SizedBox(height: 20),

        SizedBox(
          width: double.infinity,
          height: 56,
          child: FilledButton.icon(
            onPressed: _generating ? null : _generate,
            icon: _generating
                ? const SizedBox(
                    height: 22,
                    width: 22,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.auto_awesome),
            label: Text(
              _generating
                  ? tr(context, 'create.generating')
                  : tr(context, 'create.generate'),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          height: 48,
          child: OutlinedButton.icon(
            onPressed: _generating ? null : _openAlgoSheet,
            icon: const Icon(Icons.casino),
            label: Text(tr(context, 'create.generateAuto')),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          _selectedClothIds.isEmpty
              ? tr(context, 'create.autoHintEmpty')
              : '${tr(context, 'create.autoHintPre')} '
                  '${_selectedClothIds.length} ${trPlural(context, 'wardrobe.item', _selectedClothIds.length)} '
                  '${tr(context, 'create.autoHintPost')}',
          style: const TextStyle(color: Colors.grey, fontSize: 12),
        ),
        const SizedBox(height: 32),
        ], // end AI-mode section

        Row(children: [
          SectionHeader(tr(context, 'create.history')),
          const Spacer(),
          TextButton.icon(
            onPressed: _generating ? null : _openHistorySort,
            icon: Icon(Icons.sort,
                color: _outfitQuery.isActive
                    ? Theme.of(context).colorScheme.primary
                    : null),
            label: Text(tr(context, 'filter.title')),
          ),
        ]),
        const SizedBox(height: 8),
        // Its own listenable subtree: generating, favouriting or deleting an
        // outfit repaints the grid only, not the whole (long) form above it.
        AnimatedBuilder(
          animation: _history,
          builder: (context, _) {
            if (_history.isEmpty) {
              return Text(
                  _outfitQuery.isActive
                      ? tr(context, 'create.historyNoMatch')
                      : tr(context, 'create.historyEmpty'),
                  style: const TextStyle(color: Colors.grey));
            }
            final items = _history.items;
            return Column(children: [
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                  childAspectRatio: 0.85,
                ),
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final o = items[i];
                  return OutfitHistoryCard(
                    outfit: o,
                    // Manual outfits reopen in the builder to edit; AI ones
                    // (incl. failed, so the user can retry) open the result
                    // dialog.
                    onTap: () =>
                        o.isManual ? _openBuilder(existing: o) : _showResult(o),
                    onDelete: () => _confirmDeleteOutfit(o),
                    onToggleFavorite: () => _toggleFavorite(o),
                  );
                },
              ),
              // The history lives inside the page's ListView, so there is no
              // separate scroll position to hang an infinite scroller off —
              // an explicit button is both simpler and clearer here.
              if (_history.hasMore)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: _history.isLoading
                      ? const CircularProgressIndicator()
                      : OutlinedButton.icon(
                          onPressed: _history.loadMore,
                          icon: const Icon(Icons.expand_more),
                          label: Text(trOr(context, 'create.historyMore',
                              'Show more')),
                        ),
                ),
            ]);
          },
        ),
      ]),
    );
  }
}

