import 'package:flutter/material.dart';

import '../l10n/app_text.dart';
import '../models/cloth.dart';
import '../services/clothes_service.dart';

/// Bottom sheet that lets the user set sort order and filter the collection
/// by text search, brand, color, cut, and tag.
class FilterSheet extends StatefulWidget {
  const FilterSheet({
    super.key,
    required this.filter,
    required this.availableBrands,
    required this.availableTags,
  });

  final ClothFilter filter;
  final List<String> availableBrands;
  final List<String> availableTags;

  @override
  State<FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<FilterSheet> {
  late final TextEditingController _search;
  late final TextEditingController _brand;
  late final TextEditingController _tag;
  late String? _color;
  late String? _cut;
  late String? _category;
  late String? _sort;
  int? _minScore;

  @override
  void initState() {
    super.initState();
    _search = TextEditingController(text: widget.filter.search ?? '');
    _brand = TextEditingController(text: widget.filter.brand ?? '');
    _tag = TextEditingController(text: widget.filter.tag ?? '');
    _color = widget.filter.color;
    _cut = widget.filter.cut;
    _category = widget.filter.category;
    _sort = widget.filter.sort ?? 'newest';
    _minScore = (widget.filter.minScore != null && widget.filter.minScore! > 0)
        ? widget.filter.minScore
        : null;
  }

  @override
  void dispose() {
    _search.dispose();
    _brand.dispose();
    _tag.dispose();
    super.dispose();
  }

  ClothFilter _current() => ClothFilter(
        search: _search.text.trim().isEmpty ? null : _search.text.trim(),
        brand: _brand.text.trim().isEmpty ? null : _brand.text.trim(),
        tag: _tag.text.trim().isEmpty ? null : _tag.text.trim(),
        color: _color,
        cut: _cut,
        category: _category,
        sort: _sort,
        minScore: _minScore,
        // Carried through, not re-derived: favourites-only is toggled from the
        // app bar heart, not from this sheet, so defaulting it to false made
        // applying any filter silently turn the heart's mode off.
        favorite: widget.filter.favorite,
      );

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16, 16, 16, 16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(tr(context, 'filter.title'),
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold)),
                TextButton(
                  onPressed: () {
                    _search.clear();
                    _brand.clear();
                    _tag.clear();
                    setState(() {
                      _color = null;
                      _cut = null;
                      _category = null;
                      _sort = 'newest';
                      _minScore = null;
                    });
                    Navigator.pop(context, ClothFilter(sort: 'newest'));
                  },
                  child: Text(tr(context, 'filter.reset')),
                ),
              ],
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              // Key on the value so the Reset button (which changes these
              // fields externally) rebuilds the field with the new initialValue.
              key: ValueKey('sort-$_sort'),
              initialValue: _sort,
              // Outlined with a label, like every other field in this sheet.
              // It was the one control left underlined, with its name floating
              // above it as a separate line.
              decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  labelText: tr(context, 'filter.sortBy')),
              items: [
                DropdownMenuItem(
                    value: 'newest', child: Text(tr(context, 'filter.sortNewest'))),
                DropdownMenuItem(
                    value: 'name', child: Text(tr(context, 'filter.sortNameAsc'))),
                DropdownMenuItem(
                    value: 'brand', child: Text(tr(context, 'filter.sortBrandAsc'))),
                DropdownMenuItem(
                    value: 'category',
                    child: Text(tr(context, 'filter.sortCategoryAsc'))),
                DropdownMenuItem(
                    value: 'score',
                    child: Text(tr(context, 'filter.sortRatingHigh'))),
                DropdownMenuItem(
                    value: 'score_asc',
                    child: Text(tr(context, 'filter.sortRatingLow'))),
                DropdownMenuItem(
                    value: 'worn', child: Text(tr(context, 'filter.sortMostWorn'))),
                DropdownMenuItem(
                    value: 'worn_asc',
                    child: Text(tr(context, 'filter.sortLeastWorn'))),
              ],
              onChanged: (v) => setState(() => _sort = v),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _search,
              decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  labelText: tr(context, 'filter.searchByName')),
            ),
            const SizedBox(height: 12),
            Autocomplete<String>(
              optionsBuilder: (v) => widget.availableBrands
                  .where((b) => b.toLowerCase().contains(v.text.toLowerCase())),
              fieldViewBuilder: (c, ctrl, fn, onSub) {
                _brand.text = ctrl.text;
                ctrl.addListener(() => _brand.text = ctrl.text);
                return TextField(
                  controller: ctrl,
                  focusNode: fn,
                  decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      labelText: tr(context, 'filter.brand')),
                  onSubmitted: (_) => onSub(),
                );
              },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: ValueKey('color-$_color'),
              initialValue: _color,
              decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  labelText: tr(context, 'filter.color')),
              items: [
                DropdownMenuItem(
                    value: null, child: Text(tr(context, 'filter.anyColor'))),
                ...kColorPalette
                    .map((c) => DropdownMenuItem(value: c, child: Text(colorName(context, c)))),
              ],
              onChanged: (v) => setState(() => _color = v),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: ValueKey('cut-$_cut'),
              initialValue: _cut,
              decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  labelText: tr(context, 'filter.cut')),
              items: [
                DropdownMenuItem(
                    value: null, child: Text(tr(context, 'filter.anyCut'))),
                ...kCutOptions
                    .map((c) => DropdownMenuItem(value: c, child: Text(cutLabel(context, c)))),
              ],
              onChanged: (v) => setState(() => _cut = v),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: ValueKey('category-$_category'),
              initialValue: _category,
              isExpanded: true,
              decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  labelText: tr(context, 'filter.category')),
              items: [
                DropdownMenuItem(
                    value: null, child: Text(tr(context, 'filter.anyCategory'))),
                ...kCategoryOptions.map((c) =>
                    DropdownMenuItem(value: c, child: Text(categoryName(context, c)))),
              ],
              onChanged: (v) => setState(() => _category = v),
            ),
            const SizedBox(height: 12),
            Autocomplete<String>(
              optionsBuilder: (v) => widget.availableTags
                  .where((t) => t.toLowerCase().contains(v.text.toLowerCase())),
              fieldViewBuilder: (c, ctrl, fn, onSub) {
                _tag.text = ctrl.text;
                ctrl.addListener(() => _tag.text = ctrl.text);
                return TextField(
                  controller: ctrl,
                  focusNode: fn,
                  decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      labelText: tr(context, 'filter.tag')),
                  onSubmitted: (_) => onSub(),
                );
              },
            ),
            const SizedBox(height: 12),
            Text(tr(context, 'filter.minRating'),
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
            const SizedBox(height: 2),
            Text(tr(context, 'filter.minRatingHint'),
                style: const TextStyle(color: Colors.grey, fontSize: 12)),
            Slider(
              value: (_minScore ?? 0).toDouble(),
              min: 0,
              max: 5,
              divisions: 5,
              label: (_minScore == null || _minScore == 0)
                  ? tr(context, 'filter.noRatingFilter')
                  : '$_minScore / 5',
              onChanged: (v) => setState(() {
                final r = v.round();
                _minScore = r == 0 ? null : r;
              }),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: FilledButton(
                onPressed: () => Navigator.pop(context, _current()),
                child: Text(tr(context, 'filter.apply')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}