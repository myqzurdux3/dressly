import 'dart:async';

import 'package:flutter/material.dart';

import '../../app.dart';
import '../../l10n/app_text.dart';
import '../../models/cloth.dart';
import '../../services/clothes_service.dart';
import '../../state/paged_list.dart';
import '../../widgets/cloth_card.dart';
import '../../widgets/filter_sheet.dart';
import '../../widgets/paged_grid.dart';
import '../cloth/add_cloth_screen.dart';
import '../cloth/cloth_detail_screen.dart';
import '../settings/settings_screen.dart';

class CollectionScreen extends StatefulWidget {
  const CollectionScreen({super.key});

  @override
  State<CollectionScreen> createState() => _CollectionScreenState();
}

class _CollectionScreenState extends State<CollectionScreen> {
  late final ClothesService _service;
  late final PagedList<Cloth> _clothes;
  ClothFilter _filter = ClothFilter(sort: 'newest');
  List<String> _brands = [];
  List<String> _tags = [];
  final _searchCtrl = TextEditingController();
  Timer? _searchDebounce;
  bool _autocompleteLoaded = false;

  @override
  void initState() {
    super.initState();
    _service = clothesServiceOf(context);
    _clothes = PagedList<Cloth>(
      // The filter is read at call time, so changing it and calling refresh()
      // is all that a new query needs.
      fetchPage: ({required limit, required offset}) =>
          _service.list(filter: _filter, limit: limit, offset: offset),
    );
    _refresh();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    _clothes.dispose();
    super.dispose();
  }

  // Search as you type, debounced so we don't hit the API on every keystroke.
  void _onSearchChanged(String v) {
    setState(() {}); // update the clear button
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () => _onSearch(v));
  }

  Future<void> _refresh() async {
    await _clothes.refresh();
    if (!mounted) return;
    if (_clothes.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${tr(context, 'wardrobe.loadFailed')}: ${_clothes.error}'),
      ));
    }
    // Autocomplete lists rarely change; fetch once, not on every refresh.
    if (!_autocompleteLoaded) {
      _autocompleteLoaded = true;
      _service.autocompleteBrands().then((b) {
        if (mounted) setState(() => _brands = b);
      }).catchError((_) {});
      _service.autocompleteTags().then((t) {
        if (mounted) setState(() => _tags = t);
      }).catchError((_) {});
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
    setState(() => _filter =
        _filter.copyWith(search: v.isEmpty ? null : v, clearSearch: v.isEmpty));
    _refresh();
  }

  Future<void> _toggleFavorite(Cloth cloth) async {
    try {
      final nowFavorite =
          await _service.toggleFavorite(cloth.id, isFavorite: !cloth.isFavorite);
      if (!mounted) return;
      if (_filter.favorite && !nowFavorite) {
        // Un-favourited while the favourites filter is on: it no longer belongs.
        _clothes.removeItem((c) => c.id == cloth.id);
      } else {
        // Patch the one card instead of refetching every page already scrolled.
        _clothes.replaceItem(
            (c) => c.id == cloth.id, cloth.copyWith(isFavorite: nowFavorite));
      }
    } catch (_) {}
  }

  Future<void> _confirmDelete(int id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(tr(context, 'wardrobe.deleteTitle')),
        content: Text(tr(context, 'wardrobe.deleteConfirm')),
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
    if (ok == true) {
      try {
        await _service.delete(id);
        _clothes.removeItem((c) => c.id == id);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${tr(context, 'wardrobe.deleteFailed')}: $e')),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.asset('assets/logo.jpg',
                  width: 30, height: 30, fit: BoxFit.cover),
            ),
            const SizedBox(width: 8),
            const Text('Dressly'),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(_filter.favorite ? Icons.favorite : Icons.favorite_border,
                color: _filter.favorite ? Colors.redAccent : null),
            tooltip: tr(context, 'wardrobe.favoriteTooltip'),
            onPressed: () {
              setState(() =>
                  _filter = _filter.copyWith(favorite: !_filter.favorite));
              _refresh();
            },
          ),
          IconButton(
            icon: const Icon(Icons.filter_list),
            tooltip: tr(context, 'wardrobe.sortFilter'),
            onPressed: _openFilters,
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: tr(context, 'profile.settings'),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const AddClothScreen()),
          );
          _refresh();
        },
        icon: const Icon(Icons.add),
        label: Text(tr(context, 'wardrobe.addClothes')),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
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
            onChanged: _onSearchChanged,
            textInputAction: TextInputAction.search,
          ),
        ),
        Expanded(
          child: PagedGrid<Cloth>(
            controller: _clothes,
            onRefresh: _refresh,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
              childAspectRatio: 0.62,
            ),
            header: (count) => Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 2),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '$count ${trPlural(context, 'wardrobe.item', count)}'
                  '${_filter.isEmpty ? '' : ' ${tr(context, 'wardrobe.matchFilters')}'}',
                  style: const TextStyle(color: Colors.white60, fontSize: 12),
                ),
              ),
            ),
            emptyBuilder: (context) => _EmptyWardrobe(filtered: !_filter.isEmpty),
            itemBuilder: (context, cloth) => ClothCard(
              cloth: cloth,
              onTap: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ClothDetailScreen(clothId: cloth.id),
                  ),
                );
                // The detail screen can change background-removal state or
                // delete the cloth, so re-read just that one item. It is gone
                // from the server when the user deleted it there.
                if (!mounted) return;
                try {
                  _clothes.replaceItem(
                      (c) => c.id == cloth.id, await _service.get(cloth.id));
                } catch (_) {
                  _clothes.removeItem((c) => c.id == cloth.id);
                }
              },
              onLongPress: () => _confirmDelete(cloth.id),
              onToggleFavorite: () => _toggleFavorite(cloth),
            ),
          ),
        ),
      ]),
    );
  }
}

class _EmptyWardrobe extends StatelessWidget {
  const _EmptyWardrobe({required this.filtered});

  final bool filtered;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.checkroom, size: 64, color: Colors.grey),
              const SizedBox(height: 12),
              Text(
                filtered
                    ? tr(context, 'wardrobe.noMatch')
                    : tr(context, 'wardrobe.empty'),
                style: const TextStyle(fontSize: 16),
              ),
              const SizedBox(height: 4),
              Text(
                tr(context, 'wardrobe.emptyHint'),
                style: const TextStyle(color: Colors.grey),
              ),
            ],
          ),
        ),
      );
}
