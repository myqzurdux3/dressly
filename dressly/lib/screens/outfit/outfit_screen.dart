import 'dart:async';

import 'package:flutter/material.dart';

import '../../state/data_bus.dart';

import '../../app.dart';
import '../../design/ds.dart';
import '../../config/api_config.dart';
import '../../l10n/app_text.dart';
import '../../models/cloth.dart';
import '../../models/model.dart';
import '../../models/outfit.dart';
import '../../services/outfits_service.dart';
import '../../state/paged_list.dart';
import '../../widgets/outfit_history_card.dart';
import '../../widgets/model_chip.dart';
import '../../widgets/outfit_sort_sheet.dart';
import '../models/add_model_screen.dart';
import '../models/models_screen.dart';
import 'cloth_picker_screen.dart';
import 'algo_preview_dialog.dart';
import 'algo_sheet.dart';
import 'manual_builder_screen.dart';
import 'outfit_collage.dart';
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
      fetchPage: ({required limit, required offset}) =>
          outfitsServiceOf(context).list(
            sort: _outfitQuery.sort,
            favorite: _outfitQuery.favorite,
            model: _outfitQuery.model,
            limit: limit,
            offset: offset,
          ),
    );
    _loadAll();
    DataBus.outfits.addListener(_refreshHistory);
    _history.addListener(_watchRenders);
  }

  void _refreshHistory() => _history.refresh();

  /// A render started elsewhere (the stylist) has no picture yet: reload the
  /// list every few seconds until none is left processing.
  Timer? _renderWatch;
  void _watchRenders() {
    if (_renderWatch != null) return;
    if (!_history.items.any((o) => o.isProcessing)) return;
    _renderWatch = Timer(const Duration(seconds: 5), () {
      _renderWatch = null;
      if (mounted) _history.refresh();
    });
  }

  @override
  void dispose() {
    DataBus.outfits.removeListener(_refreshHistory);
    _renderWatch?.cancel();
    _history.removeListener(_watchRenders);
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
      // A render takes tens of seconds; the user may well have left by now.
      if (!mounted) return;
      _history.prepend(outfit);
      _showResult(outfit);
    } catch (e) {
      _toastKey('result.generationFailed', e);
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  void _showResult(Outfit outfit, {bool startWithAi = false}) async {
    final deleted = await showDialog<bool>(
      context: context,
      builder: (_) => OutfitResultDialog(
        outfit: outfit,
        startWithAi: startWithAi,
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
                _history.replaceItem(
                  (o) => o.id == front.id,
                  front.withLinkedId(updated.id),
                );
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

  /// Open the non-AI builder (fresh, editing an existing manual outfit, or
  /// seeded with cloth ids). Folds a saved manual outfit into history, or — if
  /// the user chose "Generate with AI" — hands its clothes to AI mode.
  Future<void> _openBuilder({
    Outfit? existing,
    List<int>? initialClothIds,
  }) async {
    final res = await Navigator.push<ManualBuilderResult>(
      context,
      MaterialPageRoute(
        builder: (_) => ManualBuilderScreen(
          existing: existing,
          initialClothIds: initialClothIds,
        ),
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
    // "AI" pressed while editing an existing outfit: its AI version, on the
    // same outfit.
    if (res.thenAi) _showResult(saved, startWithAi: true);
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          trOr(
            context,
            'builder.movedToAi',
            'Clothes loaded in AI mode — pick a model and generate',
          ),
        ),
      ),
    );
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
            child: Text(tr(context, 'common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr(context, 'common.delete')),
          ),
        ],
      ),
    );
    if (ok == true) _deleteOutfit(o);
  }

  Future<void> _toggleFavorite(Outfit o) async {
    try {
      final newVal = await outfitsServiceOf(
        context,
      ).toggleFavorite(o.id, isFavorite: !o.isFavorite);
      _history.replaceItem((x) => x.id == o.id, _replaceFavorite(o, newVal));
    } catch (e) {
      _toastKey('result.favoriteFailed', e);
    }
  }

  Outfit _replaceFavorite(Outfit o, bool fav) => Outfit(
    id: o.id,
    modelId: o.modelId,
    modelName: o.modelName,
    clothIds: o.clothIds,
    cloths: o.cloths,
    prompt: o.prompt,
    generatedUrl: o.generatedUrl,
    status: o.status,
    isMock: o.isMock,
    modelTier: o.modelTier,
    modelSlug: o.modelSlug,
    view: o.view,
    linkedId: o.linkedId,
    wornToday: o.wornToday,
    isFavorite: fav,
    nextTier: o.nextTier,
    describeClothes: o.describeClothes,
    isBlacklisted: o.isBlacklisted,
    imageMode: o.imageMode,
    renderClothIds: o.renderClothIds,
    error: o.error,
    createdAt: o.createdAt,
  );

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final c = ds.colors;
    final muted = ds.typo.label.copyWith(color: c.textMuted);
    final n = _selectedClothIds.length;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: EdgeInsets.only(bottom: ds.space.xl),
          children: [
            DsHeader(
              line1: tr(context, 'create.title1'),
              line2: tr(context, 'create.title2'),
              meta: [
                if (_mode == 'ai' && n > 0)
                  '$n ${trPlural(context, 'wardrobe.item', n)}',
              ],
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: ds.space.gutter),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // AI render vs the manual (non-AI) builder.
                  DsSegment<String>(
                    options: [
                      ('ai', trOr(context, 'builder.ai', 'AI')),
                      ('manual', trOr(context, 'builder.manual', 'Manual')),
                    ],
                    value: _mode,
                    onChanged: (v) => setState(() => _mode = v),
                  ),
                  if (_mode == 'manual') ..._manualSection(context),
                  if (_mode == 'ai') ..._aiSection(context, muted),
                  _historyTitle(context),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: ds.space.gutter),
              child: _historyGrid(context, muted),
            ),
          ],
        ),
      ),
    );
  }

  /// The manual builder: what it is, and the button that opens the canvas.
  /// Saved manual outfits land in the shared history below.
  List<Widget> _manualSection(BuildContext context) => [
    DsSectionTitle(
      trOr(context, 'builder.title', 'Manual builder'),
      hint: trOr(
        context,
        'builder.intro',
        'Arrange your clothes on a background you choose. No AI — you '
            'place, move and resize each item yourself.',
      ),
    ),
    DsButton(
      label: trOr(context, 'builder.new', 'New manual outfit'),
      icon: Icons.brush,
      expand: true,
      onPressed: () => _openBuilder(),
    ),
  ];

  List<Widget> _aiSection(BuildContext context, TextStyle muted) {
    final ds = context.ds;
    final n = _selectedClothIds.length;
    return [
      // ----- Model -----
      DsSectionTitle(
        tr(context, 'create.modelSection'),
        hint: tr(context, 'create.modelHint'),
      ),
      SizedBox(
        // Two-line labels: "Modèle aléatoire" reads in full.
        height: 148,
        child: ListView(
          scrollDirection: Axis.horizontal,
          clipBehavior: Clip.none,
          children: _spaced(ds.space.s, [
            // No person: the clothes alone.
            ModelChip(
              label: tr(context, 'create.noModel'),
              icon: Icons.person_off_outlined,
              selected: _selectedModel == null && !_randomModel,
              onTap: () => setState(() {
                _selectedModel = null;
                _randomModel = false;
              }),
            ),
            // The server picks one of your models per outfit.
            ModelChip(
              label: tr(context, 'create.randomModel'),
              icon: Icons.shuffle,
              selected: _randomModel,
              onTap: () => setState(() {
                _randomModel = true;
                _selectedModel = null;
              }),
            ),
            for (final m in _models)
              ModelChip(
                label: m.name,
                thumbUrl: m.thumbImageUrl,
                selected: _selectedModel?.id == m.id && !_randomModel,
                onTap: () => setState(() {
                  _randomModel = false;
                  _selectedModel = _selectedModel?.id == m.id ? null : m;
                }),
              ),
            if (_models.isEmpty)
              ModelChip(
                label: tr(context, 'create.addModel'),
                icon: Icons.person_add_outlined,
                selected: false,
                onTap: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const AddModelScreen()),
                  );
                  _loadAll();
                },
              ),
            // Managing models sits next to the choice of one.
            ModelChip(
              label: tr(context, 'create.manage'),
              icon: Icons.tune,
              selected: false,
              onTap: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ModelsScreen()),
                );
                _loadAll();
              },
            ),
          ]),
        ),
      ),
      if (_randomModel) ...[
        DsSectionTitle(tr(context, 'create.randomGender')),
        DsSegment<String>(
          options: [
            ('', tr(context, 'create.genderAny')),
            ('male', tr(context, 'create.genderMale')),
            ('female', tr(context, 'create.genderFemale')),
          ],
          value: _randomGender,
          onChanged: (v) => setState(() => _randomGender = v),
        ),
      ],

      // ----- Clothes -----
      DsSectionTitle(tr(context, 'create.clothes')),
      if (_clothes.isEmpty)
        Text(tr(context, 'create.noClothes'), style: muted)
      else ...[
        DsButton(
          label: n == 0
              ? tr(context, 'create.pickClothes')
              : '${tr(context, 'create.editSelection')} ($n)',
          icon: Icons.checklist,
          kind: DsButtonKind.secondary,
          expand: true,
          onPressed: _pickClothes,
        ),
        if (n > 0) ...[
          SizedBox(height: ds.space.s),
          Wrap(
            spacing: ds.space.xs,
            runSpacing: ds.space.xs,
            children: [
              for (final id in _selectedClothIds)
                _SelectedCloth(
                  cloth: _clothesById(id),
                  id: id,
                  onRemove: () => setState(() => _selectedClothIds.remove(id)),
                ),
            ],
          ),
        ],
      ],

      // ----- Which top to render (several upper layers chosen) -----
      if (_selectedUppers.length >= 2) ...[
        DsSectionTitle(
          tr(context, 'create.topToRender'),
          hint: tr(context, 'create.topToRenderHint'),
        ),
        Wrap(
          spacing: ds.space.xs,
          runSpacing: ds.space.xs,
          children: [
            for (final u in _selectedUppers)
              DsChip(
                label: u.name,
                selected: !_hiddenTopIds.contains(u.id),
                onTap: () => _toggleTop(u),
              ),
          ],
        ),
      ],

      // ----- One combined reference image, or one per garment -----
      DsSectionTitle(
        tr(context, 'create.imageMode'),
        hint: tr(context, 'create.imageModeHint'),
      ),
      DsSegment<String>(
        options: [
          ('collage', tr(context, 'create.imageModeCollage')),
          ('separate', tr(context, 'create.imageModeSeparate')),
        ],
        value: _imageMode,
        onChanged: (v) => setState(() => _imageMode = v),
      ),

      // ----- Optional prompt -----
      DsSectionTitle(
        tr(context, 'create.extraPrompt'),
        hint: tr(context, 'create.promptDesc'),
      ),
      TextField(
        controller: _prompt,
        maxLines: 2,
        decoration: InputDecoration(hintText: tr(context, 'create.promptHint')),
      ),
      SizedBox(height: ds.space.xs),
      CheckboxListTile(
        value: _describeClothes,
        onChanged: (v) => setState(() => _describeClothes = v ?? false),
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        dense: true,
        title: Text(tr(context, 'create.describeItems'), style: ds.typo.body),
        subtitle: Text(tr(context, 'create.describeSub'), style: muted),
      ),
      SizedBox(height: ds.space.m),

      // The wait for a render: the chosen pieces land on the table.
      if (_generating && n > 0) ...[
        OutfitCollage(
          clothes: [for (final id in _selectedClothIds) ?_clothesById(id)],
        ),
        SizedBox(height: ds.space.s),
      ],
      DsButton(
        label: _generating
            ? tr(context, 'create.generating')
            : tr(context, 'create.generate'),
        icon: Icons.auto_awesome,
        expand: true,
        onPressed: _generating ? null : _generate,
      ),
      SizedBox(height: ds.space.s),
      DsButton(
        label: tr(context, 'create.generateAuto'),
        icon: Icons.casino_outlined,
        kind: DsButtonKind.secondary,
        expand: true,
        onPressed: _generating ? null : _openAlgoSheet,
      ),
      SizedBox(height: ds.space.xs),
      Text(
        n == 0
            ? tr(context, 'create.autoHintEmpty')
            : '${tr(context, 'create.autoHintPre')} '
                  '$n ${trPlural(context, 'wardrobe.item', n)} '
                  '${tr(context, 'create.autoHintPost')}',
        style: muted,
      ),
    ];
  }

  Future<void> _pickClothes() async {
    final picked = await Navigator.push<Set<int>>(
      context,
      MaterialPageRoute(
        builder: (_) => ClothPickerScreen(initialSelected: _selectedClothIds),
      ),
    );
    if (picked != null && mounted) {
      setState(
        () => _selectedClothIds
          ..clear()
          ..addAll(picked),
      );
    }
  }

  /// Show or hide one upper garment in the render; at least one stays.
  void _toggleTop(Cloth u) => setState(() {
    if (_hiddenTopIds.contains(u.id)) {
      _hiddenTopIds.remove(u.id);
      return;
    }
    final visible = _selectedUppers
        .where((x) => !_hiddenTopIds.contains(x.id))
        .length;
    if (visible > 1) _hiddenTopIds.add(u.id);
  });

  Widget _historyTitle(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.end,
    children: [
      Expanded(child: DsSectionTitle(tr(context, 'create.history'))),
      Padding(
        padding: EdgeInsets.only(bottom: context.ds.space.s),
        child: DsChip(
          label: tr(context, 'filter.title'),
          leading: const Icon(Icons.sort, size: 16),
          selected: _outfitQuery.isActive,
          onTap: _generating ? () {} : _openHistorySort,
        ),
      ),
    ],
  );

  /// Its own listenable subtree: generating, favouriting or deleting an
  /// outfit repaints the grid only, not the long form above it.
  Widget _historyGrid(BuildContext context, TextStyle muted) {
    final ds = context.ds;
    return AnimatedBuilder(
      animation: _history,
      builder: (context, _) {
        if (_history.isEmpty) {
          return Text(
            tr(
              context,
              _outfitQuery.isActive
                  ? 'create.historyNoMatch'
                  : 'create.historyEmpty',
            ),
            style: muted,
          );
        }
        final items = _history.items;
        return Column(
          children: [
            GridView.builder(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: ds.space.s,
                mainAxisSpacing: ds.space.s,
                childAspectRatio: 0.8,
              ),
              itemCount: items.length,
              itemBuilder: (context, i) {
                final o = items[i];
                return OutfitHistoryCard(
                  key: ValueKey(o.id),
                  outfit: o,
                  // Manual outfits reopen in the builder; AI ones (failed
                  // included, to retry) open the result.
                  onTap: () =>
                      _showResult(o),
                  onDelete: () => _confirmDeleteOutfit(o),
                  onToggleFavorite: () => _toggleFavorite(o),
                );
              },
            ),
            // The history sits inside the page's list, with no scroll
            // position of its own: an explicit button beats a scroller.
            if (_history.hasMore)
              Padding(
                padding: EdgeInsets.only(top: ds.space.s),
                child: _history.isLoading
                    ? CircularProgressIndicator(color: ds.colors.accent)
                    : DsButton(
                        label: trOr(context, 'create.historyMore', 'Show more'),
                        icon: Icons.expand_more,
                        kind: DsButtonKind.secondary,
                        onPressed: _history.loadMore,
                      ),
              ),
          ],
        );
      },
    );
  }
}

List<Widget> _spaced(double gap, List<Widget> children) => [
  for (var i = 0; i < children.length; i++) ...[
    if (i > 0) SizedBox(width: gap),
    children[i],
  ],
];

/// A chosen garment: thumbnail, name, and a cross to drop it.
class _SelectedCloth extends StatelessWidget {
  const _SelectedCloth({
    required this.cloth,
    required this.id,
    required this.onRemove,
  });

  final Cloth? cloth;
  final int id;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final c = ds.colors;
    final thumb = cloth?.thumbImageUrl;
    return Container(
      height: 40,
      padding: EdgeInsets.only(left: ds.space.xs),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(ds.shape.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 15,
            backgroundColor: c.surfaceHigh,
            // A thumbnail through the cache, never the full cut-out.
            backgroundImage: thumb == null
                ? null
                : appImageProvider(imageUrl(thumb)),
          ),
          SizedBox(width: ds.space.xs),
          Text(cloth?.name ?? '#$id', style: ds.typo.label),
          IconButton(
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            tooltip: MaterialLocalizations.of(context).deleteButtonTooltip,
            icon: Icon(Icons.close, color: c.textMuted),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}
