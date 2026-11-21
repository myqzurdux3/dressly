import 'package:flutter/material.dart';

import '../design/ds.dart';
import '../l10n/app_text.dart';

/// Sort + filter options for an outfit list (history / favorites).
class OutfitQuery {
  final String sort; // newest | oldest | most_worn | least_worn | best_rated
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
  return showDsSheet<OutfitQuery>(
    context,
    title: tr(context, 'filter.title'),
    child: _OutfitSortSheet(
      initial: current,
      showFavoriteFilter: showFavoriteFilter,
    ),
  );
}

class _OutfitSortSheet extends StatefulWidget {
  const _OutfitSortSheet({
    required this.initial,
    required this.showFavoriteFilter,
  });

  final OutfitQuery initial;
  final bool showFavoriteFilter;

  @override
  State<_OutfitSortSheet> createState() => _OutfitSortSheetState();
}

class _OutfitSortSheetState extends State<_OutfitSortSheet> {
  late OutfitQuery _q = widget.initial;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DsSectionTitle(tr(context, 'filter.sortBy')),
        DsSegment<String>(
          options: [
            ('newest', tr(context, 'sort.newest')),
            ('oldest', tr(context, 'sort.oldest')),
            ('most_worn', tr(context, 'sort.mostWorn')),
            ('least_worn', tr(context, 'sort.leastWorn')),
            ('best_rated', tr(context, 'sort.bestRated')),
          ],
          value: _q.sort,
          onChanged: (v) => setState(() => _q = _q.copyWith(sort: v)),
        ),
        DsSectionTitle(tr(context, 'sort.show')),
        Wrap(
          spacing: ds.space.xs,
          runSpacing: ds.space.xs,
          children: [
            if (widget.showFavoriteFilter)
              DsChip(
                label: tr(context, 'sort.favorites'),
                selected: _q.favorite,
                onTap: () =>
                    setState(() => _q = _q.copyWith(favorite: !_q.favorite)),
              ),
            for (final (m, key) in const [
              ('with', 'sort.withModel'),
              ('none', 'sort.noModel'),
            ])
              DsChip(
                label: tr(context, key),
                selected: _q.model == m,
                onTap: () => setState(
                  () => _q = _q.copyWith(model: _q.model == m ? 'any' : m),
                ),
              ),
          ],
        ),
        SizedBox(height: ds.space.l),
        Row(
          children: [
            if (_q.isActive || widget.initial.isActive) ...[
              DsButton(
                label: tr(context, 'filter.reset'),
                kind: DsButtonKind.secondary,
                onPressed: () => Navigator.pop(context, const OutfitQuery()),
              ),
              SizedBox(width: ds.space.xs),
            ],
            Expanded(
              child: DsButton(
                label: tr(context, 'filter.apply'),
                expand: true,
                onPressed: () => Navigator.pop(context, _q),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
