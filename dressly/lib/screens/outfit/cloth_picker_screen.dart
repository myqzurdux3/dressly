import 'package:flutter/material.dart';

import '../../l10n/app_text.dart';

import '../../app.dart';
import '../../models/cloth.dart';
import '../../services/clothes_service.dart';
import '../../widgets/app_image.dart';
import '../../widgets/filter_sheet.dart';

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
      final clothes = await _service.list(filter: _filter);
      _service.autocompleteBrands().then((b) {
        if (mounted) setState(() => _brands = b);
      }).catchError((_) {});
      _service.autocompleteTags().then((t) {
        if (mounted) setState(() => _tags = t);
      }).catchError((_) {});
      return clothes;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('${tr(context, 'wardrobe.loadFailed')}: $e')));
      }
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
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context, null),
        ),
        title: Text('${_selected.length} ${tr(context, 'picker.selected')}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, _selected),
            child: Text(tr(context, 'common.done'),
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _searchCtrl,
                decoration: InputDecoration(
                  hintText: tr(context, 'wardrobe.searchHint'),
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _searchCtrl.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            _searchCtrl.clear();
                            _onSearch('');
                          },
                        ),
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onSubmitted: _onSearch,
                onChanged: (_) => setState(() {}),
                textInputAction: TextInputAction.search,
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.filter_list),
              tooltip: tr(context, 'filter.title'),
              onPressed: _openFilters,
            ),
          ]),
        ),
        Expanded(
          child: FutureBuilder(
            future: _future,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              final items = snapshot.data ?? [];
              _lastItems = items;
              if (items.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      _filter.isEmpty
                          ? tr(context, 'wardrobe.empty')
                          : tr(context, 'wardrobe.noMatch'),
                      style: const TextStyle(color: Colors.grey),
                      textAlign: TextAlign.center,
                    ),
                  ),
                );
              }
              return GridView.builder(
                padding: const EdgeInsets.all(8),
                gridDelegate:
                    const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                  childAspectRatio: 0.72,
                ),
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final c = items[i];
                  final selected = _selected.contains(c.id);
                  // Block picking two clothes of the same slot (e.g. jeans +
                  // joggers): an outfit can only wear one.
                  final clash = selected ? null : _conflictingSelection(c);
                  final blocked = clash != null;
                  return _PickTile(
                    cloth: c,
                    selected: selected,
                    blocked: blocked,
                    onTap: () {
                      if (clash != null) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(
                              '${tr(context, 'picker.alreadyPicked')} "${clash.name}" '
                              '(${outfitSlotLabel(context, c.category)}) — ${tr(context, 'picker.removeFirst')}'),
                        ));
                        return;
                      }
                      _toggle(c, !selected);
                    },
                  );
                },
              );
            },
          ),
        ),
      ]),
    );
  }
}

class _PickTile extends StatelessWidget {
  const _PickTile({
    required this.cloth,
    required this.selected,
    required this.blocked,
    required this.onTap,
  });
  final Cloth cloth;
  final bool selected;
  final bool blocked; // conflicts with an already-selected item → greyed out
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: blocked ? 0.4 : 1.0,
      child: GestureDetector(
        onTap: onTap,
        child: Stack(children: [
          Card(
            clipBehavior: Clip.antiAlias,
            margin: EdgeInsets.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Container(
                    color: Colors.blueGrey.shade900,
                    child: cloth.thumbImageUrl == null
                        ? const Center(
                            child: Icon(Icons.checkroom,
                                color: Colors.white38, size: 36))
                        : AppImage.path(
                            // The grid thumbnail, ~26 KB. This used to load
                            // the stored cut-out — a median of 756 KB — for
                            // every cloth in the wardrobe at once.
                            cloth.thumbImageUrl,
                            cacheKey: cloth.thumbImageUrl,
                            fit: BoxFit.contain,
                            memWidth: 600, // match the wardrobe — 200 was too soft
                          ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 4, 6, 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(cloth.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 12, fontWeight: FontWeight.bold)),
                      if (cloth.category.isNotEmpty)
                        Text(categoryName(context, cloth.category),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 10, color: Colors.white54)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            top: 4,
            right: 4,
            child: Container(
              decoration: BoxDecoration(
                color: selected ? Colors.teal : Colors.black54,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white24),
              ),
              padding: const EdgeInsets.all(2),
              child: Icon(
                selected ? Icons.check : Icons.add,
                size: 18,
                color: Colors.white,
              ),
            ),
          ),
        ]),
      ),
    );
  }
}