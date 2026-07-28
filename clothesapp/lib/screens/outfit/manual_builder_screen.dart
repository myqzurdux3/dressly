import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../app.dart';
import '../../config/api_config.dart';
import '../../l10n/app_text.dart';
import '../../models/cloth.dart';
import '../../models/outfit.dart';
import 'algo_sheet.dart';
import 'cloth_picker_screen.dart';

/// What the builder hands back to the Outfits screen when it closes: either a
/// saved/updated manual outfit, or a request to continue this outfit's clothes
/// in AI mode ("switch to AI").
class ManualBuilderResult {
  ManualBuilderResult.saved(this.saved) : toAiClothIds = null;
  ManualBuilderResult.toAi(this.toAiClothIds) : saved = null;
  final Outfit? saved;
  final List<int>? toAiClothIds;
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

  Map<String, dynamic> toJson() => {
        'cloth_id': clothId,
        'x': x,
        'y': y,
        'scale': scale,
        'rotation': rotation,
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
        color: _parseHex(j['color'] as String?) ?? Colors.white,
        color2: _parseHex(j['color2'] as String?),
      );

  Gradient? get gradient => type == 'gradient' && color2 != null
      ? LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color, color2!])
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

const List<Color> _kSwatches = [
  Colors.white, Color(0xFFF2EDE4), Color(0xFFD9D9D9), Color(0xFF9E9E9E),
  Color(0xFF4A4A4A), Colors.black, Color(0xFFEED9C4), Color(0xFFD7B899),
  Color(0xFFF7C5CC), Color(0xFFF6A6B2), Color(0xFFF3D250), Color(0xFFF0A04B),
  Color(0xFFA8D5BA), Color(0xFF6DBF9C), Color(0xFF9FB4E8), Color(0xFF5C7AEA),
  Color(0xFFC9A7EB), Color(0xFF8E6BC4),
];

const List<List<Color>> _kGradients = [
  [Color(0xFFFBC2EB), Color(0xFFA6C1EE)],
  [Color(0xFFFDCB82), Color(0xFFF3777A)],
  [Color(0xFFA8EDEA), Color(0xFFFED6E3)],
  [Color(0xFFD4FC79), Color(0xFF96E6A1)],
  [Color(0xFFE0C3FC), Color(0xFF8EC5FC)],
  [Color(0xFFF5F7FA), Color(0xFFC3CFE2)],
  [Color(0xFF434343), Color(0xFF000000)],
];

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
  _Bg _bg = _Bg(type: 'solid', color: Colors.white);
  Map<int, Cloth> _clothById = {};
  int? _selected; // index in _items of the selected garment
  bool _loading = true;
  bool _saving = false;
  AlgoPick? _lastPick; // last algo config, so re-roll can reuse it in one tap
  bool _algoRunning = false;

  // Drag/scale/rotate gesture anchors for the active item.
  double _startScale = 1.0;
  double _startRotation = 0.0;

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
      _bg = _Bg.fromJson((layout['background'] as Map?)?.cast<String, dynamic>() ??
          {'type': 'solid', 'color': '#FFFFFF'});
      for (final raw in (layout['items'] as List? ?? [])) {
        final m = (raw as Map).cast<String, dynamic>();
        final id = m['cloth_id'] as int;
        final url = _cutoutUrl(id);
        if (url == null) continue;
        _items.add(_Item(
          clothId: id,
          url: url,
          x: (m['x'] as num?)?.toDouble() ?? 0.5,
          y: (m['y'] as num?)?.toDouble() ?? 0.5,
          scale: (m['scale'] as num?)?.toDouble() ?? 1.0,
          rotation: (m['rotation'] as num?)?.toDouble() ?? 0.0,
        ));
      }
    } else if (widget.initialClothIds != null) {
      _addClothIds(widget.initialClothIds!);
    } else if (widget.existing != null) {
      // Manual outfit without a stored layout (shouldn't normally happen):
      // fall back to auto-placing its clothes so it's still editable.
      _addClothIds(widget.existing!.clothIds);
    }
    if (mounted) setState(() => _loading = false);
    _precache();
  }

  String? _cutoutUrl(int id) {
    final rel = _clothById[id]?.displayImageUrl;
    return (rel == null || rel.isEmpty) ? null : apiUrl(rel);
  }

  void _precache() {
    for (final it in _items) {
      precacheImage(CachedNetworkImageProvider(it.url), context);
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

  void _addClothIds(Iterable<int> ids) {
    final present = _items.map((e) => e.clothId).toSet();
    var n = 0;
    for (final id in ids) {
      if (present.contains(id)) continue;
      final url = _cutoutUrl(id);
      if (url == null) continue;
      // Stagger duplicates on the same row so they don't stack exactly.
      final x = 0.5 + ((n.isEven ? 1 : -1) * 0.02 * n).clamp(-0.25, 0.25);
      _items.add(_Item(clothId: id, url: url, x: x, y: _defaultY(id)));
      present.add(id);
      n++;
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
      builder: (_) => AlgoSheet(
          clothes: _clothById.values.toList(), showCount: false),
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
        _toast(trOr(context, 'builder.algoEmpty', 'No matching outfit'));
        return;
      }
      // An algorithm proposes a COMPLETE outfit, so replace whatever is on the
      // canvas — otherwise successive runs pile clothes on top of each other
      // (e.g. a leftover jogging under a new pair of shorts).
      setState(() {
        _items.clear();
        _selected = null;
        _addClothIds(preview.selections.first.map((p) => p.id));
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

  Future<void> _save() async {
    if (_items.isEmpty) {
      _toast(trOr(context, 'builder.empty', 'Add at least one item'));
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
      final boundary = _canvasKey.currentContext!.findRenderObject()
          as RenderRepaintBoundary;
      // Rasterise to ~1080px on the long side regardless of screen size.
      final pr = 1080 / boundary.size.width;
      final image = await boundary.toImage(pixelRatio: pr.clamp(1.0, 4.0));
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (bytes == null) throw Exception('capture failed');
      final layout = {
        'background': _bg.toJson(),
        'items': _items.map((e) => e.toJson()).toList(),
      };
      final saved = await svc.saveManualOutfit(
        png: bytes.buffer.asUint8List(),
        clothIds: _items.map((e) => e.clothId).toList(),
        layout: layout,
        outfitId: widget.existing?.id,
      );
      if (!mounted) return;
      Navigator.pop(context, ManualBuilderResult.saved(saved));
    } catch (e) {
      if (mounted) _toast('$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Hand this outfit's clothes to AI mode so the user can render them on a
  /// model (the mirror of "open an AI outfit in the manual builder").
  void _toAi() {
    if (_items.isEmpty) {
      _toast(trOr(context, 'builder.empty', 'Add at least one item'));
      return;
    }
    Navigator.pop(context,
        ManualBuilderResult.toAi(_items.map((e) => e.clothId).toList()));
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.existing != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(editing
            ? trOr(context, 'builder.editTitle', 'Edit manual outfit')
            : trOr(context, 'builder.title', 'Manual builder')),
        actions: [
          if (_selected != null) ...[
            IconButton(
              tooltip: trOr(context, 'builder.toFront', 'Bring to front'),
              icon: const Icon(Icons.flip_to_front),
              onPressed: _bringSelectedToFront,
            ),
            IconButton(
              tooltip: tr(context, 'common.delete'),
              icon: const Icon(Icons.delete_outline),
              onPressed: _deleteSelected,
            ),
          ],
          IconButton(
            tooltip: trOr(context, 'builder.toAi', 'Generate with AI'),
            icon: const Icon(Icons.auto_awesome),
            onPressed: _saving ? null : _toAi,
          ),
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Text(tr(context, 'common.save')),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Center(
                      child: AspectRatio(
                        aspectRatio: 1,
                        child: RepaintBoundary(
                          key: _canvasKey,
                          child: _buildCanvas(),
                        ),
                      ),
                    ),
                  ),
                ),
                _buildToolbar(),
              ],
            ),
    );
  }

  Widget _buildCanvas() {
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth, h = c.maxHeight;
      final base = w * 0.42; // item box side at scale 1.0
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
              for (var i = 0; i < _items.length; i++)
                _buildItem(i, w, h, base),
            ],
          ),
        ),
      );
    });
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
          },
          onScaleUpdate: (d) {
            setState(() {
              it.x += d.focalPointDelta.dx / w;
              it.y += d.focalPointDelta.dy / h;
              it.x = it.x.clamp(0.0, 1.0);
              it.y = it.y.clamp(0.0, 1.0);
              it.scale = (_startScale * d.scale).clamp(0.25, 3.0);
              it.rotation = _startRotation + d.rotation;
            });
          },
          child: Container(
            decoration: selected
                ? BoxDecoration(
                    border: Border.all(
                        color: Theme.of(context).colorScheme.primary, width: 2),
                    borderRadius: BorderRadius.circular(6))
                : null,
            child: Image(
              image: CachedNetworkImageProvider(it.url),
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
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _toolBtn(Icons.add_photo_alternate_outlined,
                trOr(context, 'builder.addClothes', 'Clothes'), _addClothes),
            _toolBtn(Icons.auto_awesome_outlined,
                trOr(context, 'builder.useAlgo', 'Algorithm'), _runAlgorithm),
            // Appears once an algorithm has run: one tap re-runs the same config
            // for a fresh outfit, so you can keep re-rolling and see each result.
            if (_lastPick != null)
              _toolBtn(Icons.casino_outlined,
                  trOr(context, 'builder.reshuffle', 'Re-roll'), _reshuffle,
                  busy: _algoRunning),
            _toolBtn(Icons.palette_outlined,
                trOr(context, 'builder.background', 'Background'), _pickBackground),
          ],
        ),
      ),
    );
  }

  Widget _toolBtn(IconData icon, String label, VoidCallback onTap,
      {bool busy = false}) {
    return Expanded(
      child: InkWell(
        onTap: (_saving || busy) ? null : onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              busy
                  ? const SizedBox(
                      width: 24, height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(icon),
              const SizedBox(height: 4),
              Text(label, style: Theme.of(context).textTheme.labelSmall),
            ],
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
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(trOr(context, 'builder.solid', 'Solid colour'),
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final c in _kSwatches)
                  _Swatch(
                    color: c,
                    onTap: () => Navigator.pop(
                        context, _Bg(type: 'solid', color: c)),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Text(trOr(context, 'builder.gradient', 'Gradient'),
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final g in _kGradients)
                  _Swatch(
                    gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: g),
                    onTap: () => Navigator.pop(
                        context,
                        _Bg(type: 'gradient', color: g[0], color2: g[1])),
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
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          color: color,
          gradient: gradient,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.black12),
        ),
      ),
    );
  }
}
