import 'package:flutter/material.dart';

import '../../l10n/app_text.dart';

import '../../app.dart';
import '../../models/cloth.dart';
import '../../services/clothes_service.dart';
import '../../widgets/app_image.dart';
import '../../widgets/filter_sheet.dart';
import '../../design/ds.dart';
import '../wardrobe/wardrobe_card.dart' show swatchColorOf;
import '../../widgets/error_toast.dart';

/// Full-screen multi-select cloth picker, opened from the outfit screen.
/// Mirrors the collection screen's search + sort/filter, but each tile has a
/// checkbox and the same-category guard ("no two of the same type") is applied
/// so the user can't build an outfit with two tops / two bottoms etc.
///
/// Pops with the selected cloth IDs (a `Set<int>`).
class ClothPickerScreen extends StatefulWidget {
  const ClothPickerScreen({super.key, required this.initialSelected});

  final Set<int> initialSelected;

  @override
  State<ClothPickerScreen> createState() => _ClothPickerScreenState();
}

class _ClothPickerScreenState extends State<ClothPickerScreen> {
  late final ClothesService _service;
  late Set<int> _selected;
  ClothFilter _filter = ClothFilter(sort: 'newest');
  List<String> _brands = [];
  List<String> _tags = [];
  Future<List<Cloth>>? _future;
  List<Cloth> _lastItems = [];
  final _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _service = clothesServiceOf(context);
    _selected = {...widget.initialSelected};
    _searchCtrl.text = _filter.search ?? '';
    _refresh();
    _loadSuggestions();
  }

  /// Brand and tag suggestions for the filter sheet. They do not depend on the
  /// active filter, so they are fetched once rather than on every refresh.
  void _loadSuggestions() {
    _service
        .autocompleteBrands()
        .then((b) {
          if (mounted) setState(() => _brands = b);
        })
        .catchError((_) {});
    _service
        .autocompleteTags()
        .then((t) {
          if (mounted) setState(() => _tags = t);
        })
        .catchError((_) {});
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    // Block body (not an arrow): an arrow returns the assignment's value (the
    // Future), which trips Flutter's "setState callback returned a Future"
    // assertion — the crash reported when opening the cloth picker.
    setState(() {
      _future = _fetch();
    });
    await _future;
  }

  Future<List<Cloth>> _fetch() async {
    try {
      return await _service.list(filter: _filter);
    } catch (e) {
      toastError(e, prefixKey: 'wardrobe.loadFailed');
      return <Cloth>[];
    }
  }

  Future<void> _openFilters() async {
    final result = await showModalBottomSheet<ClothFilter>(
      context: context,
      isScrollControlled: true,
      builder: (_) => FilterSheet(
        filter: _filter,
        availableBrands: _brands,
        availableTags: _tags,
      ),
    );
    if (result != null && mounted) {
      setState(() => _filter = result);
      _refresh();
    }
  }

  void _onSearch(String v) {
    setState(() => _filter = _filter.copyWith(search: v.isEmpty ? null : v));
    _refresh();
  }

  /// The already-selected item (if any) whose outfit slot clashes with [c] —
  /// e.g. a jean when [c] is joggers (both bottoms). null = no clash. Selecting
  /// it is blocked so an outfit can never contain two of the same slot.
  Cloth? _conflictingSelection(Cloth c) {
    if (c.category.isEmpty) return null;
    for (final id in _selected) {
      if (id == c.id) continue;
      final other = _lastItems.where((x) => x.id == id).firstOrNull;
      if (other != null &&
          outfitCategoriesConflict(other.category, c.category)) {
        return other;
      }
    }
    return null;
  }

  void _toggle(Cloth c, bool v) {
    setState(() {
      if (v) {
        _selected.add(c.id);
      } else {
        _selected.remove(c.id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final c = ds.colors;
    final muted = ds.typo.label.copyWith(color: c.textMuted);
    final pad = ds.space.gutter;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(pad, ds.space.s, pad, 0),
              child: Row(
                children: [
                  DsButton.icon(
                    icon: Icons.close,
                    semanticLabel: MaterialLocalizations.of(
                      context,
                    ).closeButtonTooltip,
                    onPressed: () => Navigator.pop(context, null),
                  ),
                  SizedBox(width: ds.space.s),
                  Expanded(
                    child: Text(
                      '${_selected.length} ${tr(context, 'picker.selected')}'
                          .toUpperCase(),
                      style: ds.typo.mono,
                    ),
                  ),
                  DsButton(
                    label: tr(context, 'common.done'),
                    icon: Icons.check,
                    onPressed: () => Navigator.pop(context, _selected),
                  ),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(pad, ds.space.s, pad, ds.space.s),
              child: Row(
                children: [
                  Expanded(
                    child: DsSearchField(
                      controller: _searchCtrl,
                      hint: tr(context, 'wardrobe.searchHint'),
                      clearLabel: tr(context, 'common.clear'),
                      // Searched on submit; clearing searches right away.
                      onChanged: (v) {
                        if (v.isEmpty) _onSearch('');
                      },
                      onSubmitted: _onSearch,
                    ),
                  ),
                  SizedBox(width: ds.space.xs),
                  DsButton.icon(
                    icon: Icons.tune,
                    semanticLabel: tr(context, 'filter.title'),
                    onPressed: _openFilters,
                  ),
                ],
              ),
            ),
            Expanded(
              child: FutureBuilder(
                future: _future,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return Center(
                      child: CircularProgressIndicator(color: c.accent),
                    );
                  }
                  final items = snapshot.data ?? [];
                  _lastItems = items;
                  if (items.isEmpty) {
                    return Center(
                      child: Padding(
                        padding: EdgeInsets.all(ds.space.l),
                        child: Text(
                          tr(
                            context,
                            _filter.isEmpty
                                ? 'wardrobe.empty'
                                : 'wardrobe.noMatch',
                          ),
                          style: muted,
                          textAlign: TextAlign.center,
                        ),
                      ),
                    );
                  }
                  return GridView.builder(
                    padding: EdgeInsets.fromLTRB(pad, 0, pad, ds.space.l),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      crossAxisSpacing: ds.space.xs,
                      mainAxisSpacing: ds.space.xs,
                      childAspectRatio: 0.7,
                    ),
                    itemCount: items.length,
                    itemBuilder: (context, i) {
                      final cl = items[i];
                      final selected = _selected.contains(cl.id);
                      // One garment per slot (no jeans + joggers).
                      final clash = selected ? null : _conflictingSelection(cl);
                      return _PickTile(
                        key: ValueKey(cl.id),
                        cloth: cl,
                        selected: selected,
                        blocked: clash != null,
                        onTap: () {
                          if (clash != null) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  '${tr(context, 'picker.alreadyPicked')} '
                                  '"${clash.name}" '
                                  '(${outfitSlotLabel(context, cl.category)}) '
                                  '— ${tr(context, 'picker.removeFirst')}',
                                ),
                              ),
                            );
                            return;
                          }
                          _toggle(cl, !selected);
                        },
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A garment to pick: its cut-out on its own colour, name and type under it.
/// Selected = accent frame and check; blocked (slot taken) = faded.
class _PickTile extends StatelessWidget {
  const _PickTile({
    super.key,
    required this.cloth,
    required this.selected,
    required this.blocked,
    required this.onTap,
  });

  final Cloth cloth;
  final bool selected;
  final bool blocked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final c = ds.colors;
    final tone = garmentTone(
      swatchColorOf(cloth),
      Theme.of(context).brightness,
    );
    return Opacity(
      opacity: blocked ? 0.4 : 1,
      child: DsPressable(
        onTap: onTap,
        child: AnimatedContainer(
          duration: ds.motion.fast,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(ds.shape.small),
            border: Border.all(
              color: selected ? c.accent : c.surface,
              width: 2.5,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ColoredBox(
                      color: tone.fill,
                      child: cloth.thumbImageUrl == null
                          ? Icon(Icons.checkroom, color: tone.shade, size: 32)
                          // The grid thumbnail (~26 KB), never the stored
                          // cut-out (median 756 KB) for the whole wardrobe.
                          : AppImage.path(
                              cloth.thumbImageUrl,
                              cacheKey: cloth.thumbImageUrl,
                              fit: BoxFit.contain,
                              memWidth: 600,
                            ),
                    ),
                    Positioned(
                      top: ds.space.xs,
                      right: ds.space.xs,
                      child: AnimatedContainer(
                        duration: ds.motion.fast,
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: selected
                              ? c.accent
                              : c.bg.withValues(alpha: 0.6),
                        ),
                        child: Icon(
                          selected ? Icons.check : Icons.add,
                          size: 16,
                          color: selected ? c.onAccent : c.text,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  ds.space.xs,
                  ds.space.xs,
                  ds.space.xs,
                  ds.space.xs,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      cloth.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ds.typo.label.copyWith(color: c.text),
                    ),
                    if (cloth.category.isNotEmpty)
                      Text(
                        categoryName(context, cloth.category).toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ds.typo.monoSmall.copyWith(color: c.textMuted),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
