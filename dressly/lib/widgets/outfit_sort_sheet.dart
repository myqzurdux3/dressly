import 'package:flutter/material.dart';

import '../l10n/app_text.dart';

/// Sort + filter options for an outfit list (history / favorites).
class OutfitQuery {
  final String sort; // newest | oldest | most_worn | least_worn
  final bool favorite; // only favorited outfits
  final String model; // any | with | none
  const OutfitQuery({
    this.sort = 'newest',
    this.favorite = false,
    this.model = 'any',
  });

  OutfitQuery copyWith({String? sort, bool? favorite, String? model}) =>
      OutfitQuery(
        sort: sort ?? this.sort,
        favorite: favorite ?? this.favorite,
        model: model ?? this.model,
      );

  /// Any non-default sort/filter is active (drives the button highlight).
  bool get isActive => sort != 'newest' || favorite || model != 'any';
}

/// Opens the sort/filter sheet. [showFavoriteFilter] is false on the Saved tab
/// (it's already favorites-only), but the model filter still applies there.
/// Returns the chosen query, or null if dismissed.
Future<OutfitQuery?> showOutfitSortSheet(
  BuildContext context,
  OutfitQuery current, {
  bool showFavoriteFilter = true,
}) {
  return showModalBottomSheet<OutfitQuery>(
    context: context,
    isScrollControlled: true,
    builder: (_) =>
        _OutfitSortSheet(initial: current, showFavoriteFilter: showFavoriteFilter),
  );
}

class _OutfitSortSheet extends StatefulWidget {
  const _OutfitSortSheet(
      {required this.initial, required this.showFavoriteFilter});
  final OutfitQuery initial;
  final bool showFavoriteFilter;

  @override
  State<_OutfitSortSheet> createState() => _OutfitSortSheetState();
}

class _OutfitSortSheetState extends State<_OutfitSortSheet> {
  late OutfitQuery _q;

  @override
  void initState() {
    super.initState();
    _q = widget.initial;
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Text(tr(context, 'filter.title'),
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const Spacer(),
            if (_q.isActive)
              TextButton(
                onPressed: () =>
                    Navigator.pop(context, const OutfitQuery()),
                child: Text(tr(context, 'filter.reset')),
              ),
          ]),
          const SizedBox(height: 8),
          Align(
              alignment: Alignment.centerLeft, child: Text(tr(context, 'filter.sortBy'))),
          const SizedBox(height: 4),
          DropdownButtonFormField<String>(
            initialValue: _q.sort,
            decoration: const InputDecoration(
                border: OutlineInputBorder(), isDense: true),
            items: [
              DropdownMenuItem(value: 'newest', child: Text(tr(context, 'sort.newest'))),
              DropdownMenuItem(value: 'oldest', child: Text(tr(context, 'sort.oldest'))),
              DropdownMenuItem(value: 'most_worn', child: Text(tr(context, 'sort.mostWorn'))),
              DropdownMenuItem(value: 'least_worn', child: Text(tr(context, 'sort.leastWorn'))),
            ],
            onChanged: (v) => setState(() => _q = _q.copyWith(sort: v)),
          ),
          ...[
            const SizedBox(height: 16),
            Align(
                alignment: Alignment.centerLeft, child: Text(tr(context, 'sort.show'))),
            const SizedBox(height: 6),
            Wrap(spacing: 8, children: [
              if (widget.showFavoriteFilter)
                FilterChip(
                  label: Text(tr(context, 'sort.favorites')),
                  selected: _q.favorite,
                  onSelected: (v) => setState(() => _q = _q.copyWith(favorite: v)),
                ),
              ChoiceChip(
                label: Text(tr(context, 'sort.withModel')),
                selected: _q.model == 'with',
                onSelected: (v) =>
                    setState(() => _q = _q.copyWith(model: v ? 'with' : 'any')),
              ),
              ChoiceChip(
                label: Text(tr(context, 'sort.noModel')),
                selected: _q.model == 'none',
                onSelected: (v) =>
                    setState(() => _q = _q.copyWith(model: v ? 'none' : 'any')),
              ),
            ]),
          ],
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => Navigator.pop(context, _q),
              child: Text(tr(context, 'filter.apply')),
            ),
          ),
        ]),
      ),
    );
  }
}
