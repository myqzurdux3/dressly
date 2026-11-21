import 'package:flutter/material.dart';

import '../design/ds.dart';
import '../l10n/app_text.dart';
import '../models/outfit.dart';
import 'app_image.dart';

/// Search, a favourites filter and a lazy grid of outfits to pick one from.
///
/// The grid scrolls on its own and builds only what is on screen, so a
/// history of hundreds of outfits opens instantly and the caller's confirm
/// button can stay pinned below it instead of after the last thumbnail.
class OutfitPickGrid extends StatefulWidget {
  const OutfitPickGrid({
    super.key,
    required this.outfits,
    required this.selected,
    required this.onSelected,
    this.controller,
  });

  final List<Outfit> outfits;
  final int? selected;

  /// Called with the tapped outfit's id, or null when it is tapped again.
  final ValueChanged<int?> onSelected;

  /// The sheet's scroll controller, so dragging the grid also drags the sheet.
  final ScrollController? controller;

  @override
  State<OutfitPickGrid> createState() => _OutfitPickGridState();
}

class _OutfitPickGridState extends State<OutfitPickGrid> {
  final _search = TextEditingController();
  bool _favOnly = false;
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<Outfit> get _filtered {
    final q = _query.trim().toLowerCase();
    return widget.outfits.where((o) {
      if (_favOnly && !o.isFavorite) return false;
      if (q.isEmpty) return true;
      final hay = [
        o.modelName ?? '',
        o.cloths.map((c) => c.name).join(' '),
        o.cloths.map((c) => c.brand).join(' '),
      ].join(' ').toLowerCase();
      return hay.contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final c = ds.colors;
    final muted = ds.typo.label.copyWith(color: c.textMuted);
    if (widget.outfits.isEmpty) {
      return Align(
        alignment: Alignment.topLeft,
        child: Text(tr(context, 'agenda.noOutfits'), style: muted),
      );
    }
    final outfits = _filtered;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: DsSearchField(
                controller: _search,
                hint: tr(context, 'agenda.searchHint'),
                clearLabel: tr(context, 'common.clear'),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            SizedBox(width: ds.space.xs),
            DsChip(
              label: tr(context, 'agenda.saved'),
              selected: _favOnly,
              onTap: () => setState(() => _favOnly = !_favOnly),
            ),
          ],
        ),
        SizedBox(height: ds.space.s),
        Expanded(
          child: outfits.isEmpty
              ? Align(
                  alignment: Alignment.topLeft,
                  child: Text(tr(context, 'agenda.noMatch'), style: muted),
                )
              : GridView.builder(
                  controller: widget.controller,
                  padding: EdgeInsets.only(bottom: ds.space.s),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: ds.space.xs,
                    mainAxisSpacing: ds.space.xs,
                    childAspectRatio: 0.8,
                  ),
                  itemCount: outfits.length,
                  itemBuilder: (context, i) {
                    final o = outfits[i];
                    final sel = widget.selected == o.id;
                    return GestureDetector(
                      onTap: () => widget.onSelected(sel ? null : o.id),
                      child: AnimatedContainer(
                        duration: ds.motion.fast,
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(
                          color: c.surfaceHigh,
                          borderRadius: ds.shape.smallRadius,
                          border: Border.all(
                            color: sel ? c.accent : c.hairline,
                            width: sel ? 3 : 1,
                          ),
                        ),
                        // Three per row: the grid-sized copy is plenty.
                        child: AppImage(
                          url: outfitThumbUrl(o),
                          cacheKey: outfitThumbUrl(o),
                          fit: BoxFit.cover,
                          memWidth: 160,
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// A sheet that picks one outfit and returns its id; the confirm button stays
/// on screen however long the list is.
Future<int?> showOutfitPicker(
  BuildContext context, {
  required List<Outfit> outfits,
  required String title,
  int? initial,
}) {
  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) =>
        _OutfitPickerSheet(outfits: outfits, title: title, initial: initial),
  );
}

class _OutfitPickerSheet extends StatefulWidget {
  const _OutfitPickerSheet({
    required this.outfits,
    required this.title,
    this.initial,
  });

  final List<Outfit> outfits;
  final String title;
  final int? initial;

  @override
  State<_OutfitPickerSheet> createState() => _OutfitPickerSheetState();
}

class _OutfitPickerSheetState extends State<_OutfitPickerSheet> {
  late int? _selected = widget.initial;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      minChildSize: 0.4,
      expand: false,
      builder: (context, scroll) => Padding(
        padding: EdgeInsets.fromLTRB(
          ds.space.gutter,
          0,
          ds.space.gutter,
          ds.space.m,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.title.toUpperCase(), style: ds.typo.headline),
            SizedBox(height: ds.space.s),
            Expanded(
              child: OutfitPickGrid(
                outfits: widget.outfits,
                selected: _selected,
                controller: scroll,
                onSelected: (id) => setState(() => _selected = id),
              ),
            ),
            SizedBox(height: ds.space.s),
            DsButton(
              label: tr(context, 'plan.useOutfit'),
              icon: Icons.check,
              expand: true,
              onPressed: _selected == null
                  ? null
                  : () => Navigator.pop(context, _selected),
            ),
          ],
        ),
      ),
    );
  }
}
