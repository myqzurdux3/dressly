import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../app.dart';
import '../../config/api_config.dart';
import '../../design/canvas_backgrounds.dart';
import '../../design/ds.dart';
import '../../l10n/app_text.dart';
import '../../models/cloth.dart';
import '../../models/flat_lay.dart';
import '../../models/layering.dart';
import '../../models/outfit.dart';
import 'algo_sheet.dart';
import 'cloth_picker_screen.dart';
import '../../widgets/app_image.dart';

/// What the builder hands back to the Outfits screen when it closes: either a
/// saved/updated manual outfit, or a request to continue this outfit's clothes
/// in AI mode ("switch to AI").
class ManualBuilderResult {
  ManualBuilderResult.saved(this.saved) : toAiClothIds = null, thenAi = false;
  ManualBuilderResult.toAi(this.toAiClothIds) : saved = null, thenAi = false;

  /// An existing outfit saved, then asked for its AI version.
  ManualBuilderResult.savedThenAi(this.saved)
    : toAiClothIds = null,
      thenAi = true;
  final Outfit? saved;
  final List<int>? toAiClothIds;
  final bool thenAi;
}

/// A single garment placed on the canvas. Positions are stored as fractions of
/// the canvas (0..1, centre of the item) so a layout is resolution-independent
/// and re-renders identically at any canvas size.
class _Item {
  _Item({
    required this.clothId,
    required this.url,
    required this.x,
    required this.y,
    this.scale = 1.0,
    this.rotation = 0.0,
  });
  final int clothId;
  final String url; // absolute cutout URL
  double x;
  double y;
  double scale;
  double rotation; // radians

  Map<String, dynamic> toJson({int? z}) => {
    'cloth_id': clothId,
    'x': x,
    'y': y,
    'scale': scale,
    'rotation': rotation,
    // Stacking order, written out rather than left implicit in the array
    // order, so a layout stays readable and re-orderable outside this
    // screen. The canvas paints _items in order and z mirrors that.
    if (z != null) 'z': z,
  };
}

/// Canvas background: a solid colour or a two-colour vertical gradient.
class _Bg {
  _Bg({required this.type, required this.color, this.color2});
  final String type; // 'solid' | 'gradient'
  final Color color;
  final Color? color2;

  Map<String, dynamic> toJson() => {
    'type': type,
    'color': _hex(color),
    if (color2 != null) 'color2': _hex(color2!),
  };

  static _Bg fromJson(Map<String, dynamic> j) => _Bg(
    type: (j['type'] ?? 'solid') as String,
    color: _parseHex(j['color'] as String?) ?? kCanvasDefault,
    color2: _parseHex(j['color2'] as String?),
  );

  Gradient? get gradient => type == 'gradient' && color2 != null
      ? LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color, color2!],
        )
      : null;
}

String _hex(Color c) =>
    '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

Color? _parseHex(String? s) {
  if (s == null || s.isEmpty) return null;
  var h = s.replaceFirst('#', '');
  if (h.length == 6) h = 'FF$h';
  final v = int.tryParse(h, radix: 16);
  return v == null ? null : Color(v);
}

/// Non-AI outfit builder: drop garment cutouts on a chosen background, move /
/// pinch / rotate them, then save the composed image to history (no BFL).
class ManualBuilderScreen extends StatefulWidget {
  const ManualBuilderScreen({super.key, this.existing, this.initialClothIds});

  /// Editing an existing manual outfit (its layout is reloaded).
  final Outfit? existing;

  /// Seed the canvas with these cloth ids (e.g. from an algorithm run).
  final List<int>? initialClothIds;

  @override
  State<ManualBuilderScreen> createState() => _ManualBuilderScreenState();
}

class _ManualBuilderScreenState extends State<ManualBuilderScreen> {
  final GlobalKey _canvasKey = GlobalKey();
  final List<_Item> _items = [];
  _Bg _bg = _Bg(type: 'solid', color: kCanvasDefault);
  Map<int, Cloth> _clothById = {};
  int? _selected; // index in _items of the selected garment
  bool _loading = true;
  bool _saving = false;
  AlgoPick? _lastPick; // last algo config, so re-roll can reuse it in one tap
  bool _algoRunning = false;

  // Drag/scale/rotate gesture anchors for the active item.
  double _startScale = 1.0;
  double _startRotation = 0.0;

  /// Unsnapped position of the dragged item, so snapping never fights the
  /// finger: the item follows this and only its shown place is snapped.
  double _rawX = 0, _rawY = 0;

  /// Alignment guides shown while dragging (canvas fractions), or null.
  double? _guideX, _guideY;

  /// Once the user moves something by hand, adding clothes no longer
  /// rearranges the canvas; "Arrange" does it on demand.
  bool _customized = false;

  /// Item box side at scale 1, as a fraction of the canvas: see _buildCanvas.
  static const double _baseFraction = 0.42;

  /// Lay every garment out as a tidy flat lay (see flat_lay.dart).
  void _arrange() {
    final lay = flatLay(_items.map((e) => e.clothId).toList(), _categoryOf);
    for (final it in _items) {
      final s = lay[it.clothId];
      if (s == null) continue;
      it
        ..x = s.x
        ..y = s.y
        ..scale = (s.size / _baseFraction).clamp(0.25, 3.0)
        ..rotation = 0;
    }
    _items.sort(
      (a, b) => layerRank(
        _categoryOf(a.clothId),
      ).compareTo(layerRank(_categoryOf(b.clothId))),
    );
    _selected = null;
  }

  void _arrangeIfAuto() {
    if (!_customized) _arrange();
  }

  /// Snap [v] to the centre line or to another item's centre when close.
  double _snap(
    double v,
    Iterable<double> targets,
    void Function(double?) mark,
  ) {
    const threshold = 0.015;
    for (final t in [0.5, ...targets]) {
      if ((v - t).abs() < threshold) {
        mark(t);
        return t;
      }
    }
    mark(null);
    return v;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    try {
      final clothes = await clothesServiceOf(context).list();
      _clothById = {for (final c in clothes) c.id: c};
    } catch (_) {}
    // Restore an existing layout, else seed from initial cloth ids.
    final layout = widget.existing?.layout;
    if (layout != null) {
      _bg = _Bg.fromJson(
        (layout['background'] as Map?)?.cast<String, dynamic>() ??
            {'type': 'solid', 'color': '#FFFFFF'},
      );
      // A saved layout is the user's own arrangement, stacking included: keep
      // it exactly. 'z' is read when present (it is what this screen writes);
      // older layouts carry the order in the array itself.
      final raws = (layout['items'] as List? ?? [])
          .map((raw) => (raw as Map).cast<String, dynamic>())
          .toList();
      final indexed = [for (var i = 0; i < raws.length; i++) (raws[i], i)]
        ..sort((a, b) {
          final za = (a.$1['z'] as num?)?.toInt() ?? a.$2;
          final zb = (b.$1['z'] as num?)?.toInt() ?? b.$2;
          return za.compareTo(zb);
        });
      _customized = true; // the user's own arrangement: keep it
      for (final (m, _) in indexed) {
        final id = m['cloth_id'] as int;
        final url = _cutoutUrl(id);
        if (url == null) continue;
        _items.add(
          _Item(
            clothId: id,
            url: url,
            x: (m['x'] as num?)?.toDouble() ?? 0.5,
            y: (m['y'] as num?)?.toDouble() ?? 0.5,
            scale: (m['scale'] as num?)?.toDouble() ?? 1.0,
            rotation: (m['rotation'] as num?)?.toDouble() ?? 0.0,
          ),
        );
      }
    } else if (widget.initialClothIds != null) {
      _addClothIds(widget.initialClothIds!);
      _arrange();
    } else if (widget.existing != null) {
      // An AI outfit getting its first montage, or one saved by the stylist:
      // start from a tidy flat lay of its clothes.
      _addClothIds(widget.existing!.clothIds);
      _arrange();
    }
    if (mounted) setState(() => _loading = false);
    _precache();
  }

  String? _cutoutUrl(int id) {
    // The screen-sized copy: the canvas never shows a garment larger than the
    // phone, and the stored cut-outs are around a megabyte each.
    final rel = _clothById[id]?.previewImageUrl;
    return (rel == null || rel.isEmpty) ? null : apiUrl(rel);
  }

  void _precache() {
    for (final it in _items) {
      // appImageProvider, not a bare CachedNetworkImageProvider: the latter
      // uses the package's own 200-file cache instead of the app's.
      precacheImage(appImageProvider(it.url), context);
    }
  }

  /// A sensible default Y for a garment so a freshly-added outfit reads roughly
  /// head-to-toe before the user rearranges it.
  double _defaultY(int id) {
    switch (_clothById[id]?.category ?? '') {
      case 'hat':
      case 'cap':
        return 0.12;
      case 'shoes':
      case 'socks':
        return 0.82;
      case 'shorts':
      case 'jeans':
      case 'trousers':
      case 'jogging':
      case 'skirt':
        return 0.58;
      case 'bag':
        return 0.6;
      default:
        return 0.32; // tops / dresses / outers
    }
  }

  String _categoryOf(int clothId) => _clothById[clothId]?.category ?? '';

  void _addClothIds(Iterable<int> ids) {
    final present = _items.map((e) => e.clothId).toSet();
    for (final id in ids) {
      if (present.contains(id)) continue;
      final url = _cutoutUrl(id);
      if (url == null) continue;
      final category = _categoryOf(id);
      final zone = zoneOf(category);
      final occupants = _items
          .where((it) => zoneOf(_categoryOf(it.clothId)) == zone)
          .length;
      final item = _Item(
        clothId: id,
        url: url,
        x: defaultX(occupants),
        y: _defaultY(id),
      );
      // Inserted at its place in the stack rather than appended, so the canvas
      // paints a jacket over the t-shirt whatever order they were picked in.
      // Equal ranks keep insertion order, and dragging one to the front later
      // still wins — that moves it in the list, which is what is saved.
      final rank = layerRank(category);
      final at = _items.indexWhere(
        (it) => layerRank(_categoryOf(it.clothId)) > rank,
      );
      _items.insert(at < 0 ? _items.length : at, item);
      present.add(id);
    }
    _precache();
  }

  Future<void> _addClothes() async {
    final picked = await Navigator.push<Set<int>>(
      context,
      MaterialPageRoute(
        builder: (_) => ClothPickerScreen(
          initialSelected: _items.map((e) => e.clothId).toSet(),
        ),
      ),
    );
    if (picked == null) return;
    // Remove deselected, add newly selected.
    setState(() {
      _items.removeWhere((it) => !picked.contains(it.clothId));
      _addClothIds(picked);
      _arrangeIfAuto();
      _selected = null;
    });
  }

  Future<void> _runAlgorithm() async {
    // Reuse the SAME rich sheet as AI mode: min-rating filter, clothing types,
    // weather, fill-gaps and the pick-by-* colour/brand/tag options.
    final pick = await showModalBottomSheet<AlgoPick>(
      context: context,
      isScrollControlled: true,
      // A manual outfit is one canvas — no "how many outfits" count needed.
      builder: (_) =>
          AlgoSheet(clothes: _clothById.values.toList(), showCount: false),
    );
    if (pick == null || !mounted) return;
    _lastPick = pick; // remembered so "re-roll" can rerun it in one tap
    await _applyAlgo(pick);
  }

  /// Re-run the last algorithm config for a fresh outfit without reopening the
  /// sheet — so the user can keep re-rolling and see each result immediately.
  Future<void> _reshuffle() async {
    if (_lastPick != null) await _applyAlgo(_lastPick!);
  }

  Future<void> _applyAlgo(AlgoPick pick) async {
    final svc = outfitsServiceOf(context);
    setState(() => _algoRunning = true);
    try {
      final preview = await svc.previewAlgo(
        algo: pick.algo,
        minScore: pick.minScore,
        color: pick.color,
        brand: pick.brand,
        tag: pick.tag,
        weather: pick.weather,
        categories: pick.categories,
        fillGaps: pick.fillGaps,
        count: 1,
      );
      if (!mounted) return;
      if (preview.selections.isEmpty || preview.selections.first.isEmpty) {
        _toast(tr(context, 'builder.algoEmpty'));
        return;
      }
      // An algorithm proposes a COMPLETE outfit, so replace whatever is on the
      // canvas — otherwise successive runs pile clothes on top of each other
      // (e.g. a leftover jogging under a new pair of shorts).
      setState(() {
        _items.clear();
        _selected = null;
        _addClothIds(preview.selections.first.map((p) => p.id));
        _customized = false; // a new outfit: lay it out afresh
        _arrange();
      });
    } catch (e) {
      if (mounted) _toast('$e');
    } finally {
      if (mounted) setState(() => _algoRunning = false);
    }
  }

  Future<void> _pickBackground() async {
    final result = await showModalBottomSheet<_Bg>(
      context: context,
      showDragHandle: true,
      builder: (_) => _BackgroundSheet(current: _bg),
    );
    if (result != null) setState(() => _bg = result);
  }

  Future<void> _save({bool thenAi = false}) async {
    if (_items.isEmpty) {
      _toast(tr(context, 'builder.empty'));
      return;
    }
    final svc = outfitsServiceOf(context); // resolve before any async gap
    setState(() {
      _selected = null; // hide selection chrome from the capture
      _saving = true;
    });
    try {
      // Let the frame without selection handles paint before capturing.
      await WidgetsBinding.instance.endOfFrame;
      final boundary =
          _canvasKey.currentContext!.findRenderObject()
              as RenderRepaintBoundary;
      // Rasterise to ~1080px on the long side regardless of screen size.
      final pr = 1080 / boundary.size.width;
      final image = await boundary.toImage(pixelRatio: pr.clamp(1.0, 4.0));
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (bytes == null) throw const _CaptureFailed();
      final layout = {
        'background': _bg.toJson(),
        'items': [
          for (var i = 0; i < _items.length; i++) _items[i].toJson(z: i),
        ],
      };
      final saved = await svc.saveManualOutfit(
        png: bytes.buffer.asUint8List(),
        clothIds: _items.map((e) => e.clothId).toList(),
        layout: layout,
        outfitId: widget.existing?.id,
      );
      if (!mounted) return;
      Navigator.pop(
        context,
        thenAi
            ? ManualBuilderResult.savedThenAi(saved)
            : ManualBuilderResult.saved(saved),
      );
    } catch (e) {
      if (!mounted) return;
      // Raw exception text ("Exception: capture failed") used to reach the
      // user untranslated.
      _toast(
        e is _CaptureFailed
            ? tr(context, 'builder.captureFailed')
            : '${tr(context, 'form.saveFailed')}: $e',
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Hand this outfit's clothes to AI mode so the user can render them on a
  /// model (the mirror of "open an AI outfit in the manual builder").
  void _toAi() {
    if (_items.isEmpty) {
      _toast(tr(context, 'builder.empty'));
      return;
    }
    // An existing outfit keeps one row: save the montage, then its AI
    // version is shown or rendered on that same outfit.
    if (widget.existing != null) {
      _save(thenAi: true);
      return;
    }
    Navigator.pop(
      context,
      ManualBuilderResult.toAi(_items.map((e) => e.clothId).toList()),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final c = ds.colors;
    final editing = widget.existing != null;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                ds.space.gutter,
                ds.space.s,
                ds.space.gutter,
                0,
              ),
              child: Row(
                children: [
                  DsButton.icon(
                    icon: Icons.close,
                    semanticLabel: MaterialLocalizations.of(
                      context,
                    ).closeButtonTooltip,
                    onPressed: () => Navigator.maybePop(context),
                  ),
                  SizedBox(width: ds.space.s),
                  Expanded(
                    child: Text(
                      (editing
                              ? tr(context, 'builder.editTitle')
                              : tr(context, 'builder.title'))
                          .toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ds.typo.mono,
                    ),
                  ),
                  DsButton.icon(
                    icon: Icons.auto_awesome,
                    semanticLabel: tr(context, 'builder.toAi'),
                    onPressed: _saving ? null : _toAi,
                  ),
                  SizedBox(width: ds.space.xs),
                  DsButton(
                    label: tr(context, 'common.save'),
                    loading: _saving,
                    onPressed: _saving ? null : _save,
                  ),
                ],
              ),
            ),
            Expanded(
              child: _loading
                  ? Center(child: CircularProgressIndicator(color: c.accent))
                  : Padding(
                      padding: EdgeInsets.all(ds.space.gutter),
                      child: Center(
                        child: AspectRatio(
                          aspectRatio: 1,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(ds.shape.card),
                            child: RepaintBoundary(
                              key: _canvasKey,
                              child: _buildCanvas(),
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
            // What can be done to the selected piece, right above the tools.
            AnimatedSwitcher(
              duration: ds.motion.fast,
              child: _selected == null
                  ? SizedBox(height: ds.space.s)
                  : Padding(
                      padding: EdgeInsets.only(bottom: ds.space.s),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          DsButton(
                            label: tr(context, 'builder.toFront'),
                            icon: Icons.flip_to_front,
                            kind: DsButtonKind.secondary,
                            onPressed: _bringSelectedToFront,
                          ),
                          SizedBox(width: ds.space.xs),
                          DsButton.icon(
                            icon: Icons.delete_outline,
                            semanticLabel: tr(context, 'common.delete'),
                            onPressed: _deleteSelected,
                          ),
                        ],
                      ),
                    ),
            ),
            if (!_loading) _buildToolbar(),
          ],
        ),
      ),
    );
  }

  Widget _buildCanvas() {
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth, h = c.maxHeight;
        final base = w * _baseFraction; // item box side at scale 1.0
        return GestureDetector(
          onTap: () => setState(() => _selected = null),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: _bg.gradient == null ? _bg.color : null,
              gradient: _bg.gradient,
            ),
            child: Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                const Positioned.fill(child: SizedBox()),
                // An empty canvas says what to do next. On a pill of its own
                // so it reads on any background colour.
                if (_items.isEmpty)
                  Center(
                    child: Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: context.ds.space.m,
                        vertical: context.ds.space.s,
                      ),
                      decoration: BoxDecoration(
                        color: context.ds.colors.surface,
                        borderRadius: context.ds.shape.pillRadius,
                      ),
                      child: Text(
                        tr(context, 'builder.empty'),
                        textAlign: TextAlign.center,
                        style: context.ds.typo.label.copyWith(
                          color: context.ds.colors.textMuted,
                        ),
                      ),
                    ),
                  ),
                for (var i = 0; i < _items.length; i++)
                  _buildItem(i, w, h, base),
                // Alignment guides while a garment is dragged.
                if (_guideX != null)
                  Positioned(
                    left: _guideX! * w - 0.5,
                    top: 0,
                    bottom: 0,
                    child: Container(width: 1, color: context.ds.colors.accent),
                  ),
                if (_guideY != null)
                  Positioned(
                    top: _guideY! * h - 0.5,
                    left: 0,
                    right: 0,
                    child: Container(
                      height: 1,
                      color: context.ds.colors.accent,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildItem(int i, double w, double h, double base) {
    final it = _items[i];
    final side = base * it.scale;
    final selected = _selected == i;
    return Positioned(
      left: it.x * w - side / 2,
      top: it.y * h - side / 2,
      width: side,
      height: side,
      child: Transform.rotate(
        angle: it.rotation,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onScaleStart: (_) {
            setState(() => _selected = i);
            _startScale = it.scale;
            _startRotation = it.rotation;
            _rawX = it.x;
            _rawY = it.y;
          },
          onScaleUpdate: (d) {
            setState(() {
              _customized = true;
              _rawX = (_rawX + d.focalPointDelta.dx / w).clamp(0.0, 1.0);
              _rawY = (_rawY + d.focalPointDelta.dy / h).clamp(0.0, 1.0);
              final others = [
                for (final o in _items)
                  if (!identical(o, it)) o,
              ];
              it.x = _snap(_rawX, others.map((o) => o.x), (g) => _guideX = g);
              it.y = _snap(_rawY, others.map((o) => o.y), (g) => _guideY = g);
              it.scale = (_startScale * d.scale).clamp(0.25, 3.0);
              // Straight unless clearly turned: small wobbles of two fingers
              // used to leave every garment slightly askew.
              final r = _startRotation + d.rotation;
              it.rotation = r.abs() < 0.08 ? 0 : r;
            });
          },
          onScaleEnd: (_) => setState(() {
            _guideX = null;
            _guideY = null;
          }),
          child: Container(
            decoration: selected
                ? BoxDecoration(
                    border: Border.all(
                      color: context.ds.colors.accent,
                      width: 2,
                    ),
                    borderRadius: context.ds.shape.smallRadius,
                  )
                : null,
            child: Image(
              image: appImageProvider(it.url),
              fit: BoxFit.contain,
              gaplessPlayback: true,
              filterQuality: FilterQuality.medium,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildToolbar() {
    final ds = context.ds;
    return Container(
      margin: EdgeInsets.fromLTRB(
        ds.space.gutter,
        0,
        ds.space.gutter,
        ds.space.s,
      ),
      decoration: BoxDecoration(
        color: ds.colors.surface,
        borderRadius: BorderRadius.circular(ds.shape.pill),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: ds.space.xs),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _toolBtn(
              Icons.add_photo_alternate_outlined,
              tr(context, 'builder.addClothes'),
              _addClothes,
            ),
            _toolBtn(
              Icons.grid_view_outlined,
              tr(context, 'builder.arrange'),
              () => setState(() {
                _customized = false;
                _arrange();
              }),
            ),
            _toolBtn(
              Icons.auto_awesome_outlined,
              tr(context, 'builder.useAlgo'),
              _runAlgorithm,
            ),
            // Appears once an algorithm has run: one tap re-runs the same config
            // for a fresh outfit, so you can keep re-rolling and see each result.
            if (_lastPick != null)
              _toolBtn(
                Icons.casino_outlined,
                tr(context, 'builder.reshuffle'),
                _reshuffle,
                busy: _algoRunning,
              ),
            _toolBtn(
              Icons.palette_outlined,
              tr(context, 'builder.background'),
              _pickBackground,
            ),
          ],
        ),
      ),
    );
  }

  Widget _toolBtn(
    IconData icon,
    String label,
    VoidCallback onTap, {
    bool busy = false,
  }) {
    final ds = context.ds;
    final c = ds.colors;
    return Expanded(
      child: Semantics(
        button: true,
        label: label,
        excludeSemantics: true,
        child: InkWell(
          onTap: (_saving || busy) ? null : onTap,
          borderRadius: BorderRadius.circular(ds.shape.pill),
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: ds.space.xs),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                busy
                    ? SizedBox.square(
                        dimension: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: c.accent,
                        ),
                      )
                    : Icon(icon, color: c.text),
                SizedBox(height: ds.space.xs),
                Text(
                  label.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ds.typo.monoSmall.copyWith(color: c.textMuted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _bringSelectedToFront() {
    if (_selected == null) return;
    setState(() {
      final it = _items.removeAt(_selected!);
      _items.add(it);
      _selected = _items.length - 1;
    });
  }

  void _deleteSelected() {
    if (_selected == null) return;
    setState(() {
      _items.removeAt(_selected!);
      _selected = null;
    });
  }
}

/// Bottom sheet to pick a solid colour swatch or a gradient preset.
class _BackgroundSheet extends StatelessWidget {
  const _BackgroundSheet({required this.current});
  final _Bg current;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          context.ds.space.gutter,
          0,
          context.ds.space.gutter,
          context.ds.space.m,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DsSectionTitle(tr(context, 'builder.solid')),
            Wrap(
              spacing: context.ds.space.s,
              runSpacing: context.ds.space.s,
              children: [
                for (final c in kCanvasSwatches)
                  _Swatch(
                    color: c,
                    onTap: () =>
                        Navigator.pop(context, _Bg(type: 'solid', color: c)),
                  ),
              ],
            ),
            DsSectionTitle(tr(context, 'builder.gradient')),
            Wrap(
              spacing: context.ds.space.s,
              runSpacing: context.ds.space.s,
              children: [
                for (final g in kCanvasGradients)
                  _Swatch(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: g,
                    ),
                    onTap: () => Navigator.pop(
                      context,
                      _Bg(type: 'gradient', color: g[0], color2: g[1]),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({this.color, this.gradient, required this.onTap});
  final Color? color;
  final Gradient? gradient;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          color: color,
          gradient: gradient,
          shape: BoxShape.circle,
          border: Border.all(color: ds.colors.hairline),
        ),
      ),
    );
  }
}

/// The canvas could not be rasterised; reported with a translated message.
class _CaptureFailed implements Exception {
  const _CaptureFailed();
}
