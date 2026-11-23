import 'package:flutter/material.dart';

import '../../config/api_config.dart';
import '../../design/ds.dart';
import '../../services/outfits_service.dart';

import '../../l10n/app_text.dart';
import '../../models/cloth.dart';
import '../../widgets/app_image.dart';
import 'algo_sheet.dart';

class AlgoPreviewDialog extends StatefulWidget {
  const AlgoPreviewDialog({
    super.key,
    required this.pick,
    required this.initial,
    required this.onReshuffle,
  });
  final AlgoPick pick;
  final AlgoPreview initial;
  final Future<AlgoPreview> Function() onReshuffle;

  @override
  State<AlgoPreviewDialog> createState() => _AlgoPreviewDialogState();
}

class _AlgoPreviewDialogState extends State<AlgoPreviewDialog> {
  late AlgoPreview _preview;
  // Which proposed selections the user wants to actually render. Starts with
  // all ticked; unticking one skips it so no credits are spent on it.
  late Set<int> _chosen;
  bool _reshuffling = false;

  @override
  void initState() {
    super.initState();
    _preview = widget.initial;
    _chosen = {for (var i = 0; i < _preview.selections.length; i++) i};
  }

  Future<void> _doReshuffle() async {
    setState(() => _reshuffling = true);
    try {
      final next = await widget.onReshuffle();
      if (mounted) {
        setState(() {
          _preview = next;
          _chosen = {for (var i = 0; i < next.selections.length; i++) i};
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${tr(context, 'result.reshuffleFailed')}: $e'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _reshuffling = false);
    }
  }

  void _confirm() {
    // Render only the ticked selections, preserving order.
    final chosen = [
      for (var i = 0; i < _preview.selections.length; i++)
        if (_chosen.contains(i)) _preview.selections[i],
    ];
    Navigator.pop(
      context,
      AlgoPreview(
        algo: _preview.algo,
        algoLabel: _preview.algoLabel,
        selections: chosen,
      ),
    );
  }

  /// The server's label ("Same brand · Nike") with the algorithm's own name
  /// translated; the part after the dot (a brand, a colour) stays as is.
  String _title(BuildContext context) {
    final parts = _preview.algoLabel.split(' · ');
    parts[0] = trOr(context, 'algoName.${_preview.algo}', parts[0]);
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final c = ds.colors;
    final muted = ds.typo.label.copyWith(color: c.textMuted);
    final n = _preview.selections.length;
    final k = _chosen.length;
    return Dialog(
      insetPadding: EdgeInsets.symmetric(
        horizontal: ds.space.s,
        vertical: ds.space.l,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 760),
        child: Padding(
          padding: EdgeInsets.all(ds.space.m),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _title(context).toUpperCase(),
                          style: ds.typo.headline,
                        ),
                        Text(
                          trPlural(context, 'algo.proposed', n).toUpperCase(),
                          style: ds.typo.monoSmall.copyWith(color: c.textMuted),
                        ),
                      ],
                    ),
                  ),
                  DsButton.icon(
                    icon: Icons.close,
                    semanticLabel: MaterialLocalizations.of(
                      context,
                    ).closeButtonTooltip,
                    onPressed: () => Navigator.pop(context, null),
                  ),
                ],
              ),
              SizedBox(height: ds.space.xs),
              Text(tr(context, 'algo.pickWhich'), style: muted),
              SizedBox(height: ds.space.s),
              Flexible(
                child: _reshuffling
                    ? Center(child: CircularProgressIndicator(color: c.accent))
                    : ListView.separated(
                        shrinkWrap: true,
                        itemCount: n,
                        separatorBuilder: (_, _) =>
                            SizedBox(height: ds.space.s),
                        itemBuilder: (context, i) => _AlgoSelectionCard(
                          index: i + 1,
                          picks: _preview.selections[i],
                          chosen: _chosen.contains(i),
                          onToggle: () => setState(() {
                            if (!_chosen.remove(i)) _chosen.add(i);
                          }),
                        ),
                      ),
              ),
              SizedBox(height: ds.space.s),
              Row(
                children: [
                  DsButton(
                    label: tr(context, 'result.reshuffle'),
                    icon: Icons.refresh,
                    kind: DsButtonKind.secondary,
                    onPressed: _reshuffling ? null : _doReshuffle,
                  ),
                  SizedBox(width: ds.space.xs),
                  Expanded(
                    child: DsButton(
                      // "Generate (3)": the full "Generate 3 outfits" did not
                      // fit next to Reshuffle on a phone.
                      label: '${tr(context, 'result.generate')} ($k)',
                      icon: Icons.auto_awesome,
                      expand: true,
                      onPressed: (_reshuffling || k == 0) ? null : _confirm,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One proposed outfit, head to toe as layers. Tap anywhere to keep or skip
/// it: a skipped one costs no render.
class _AlgoSelectionCard extends StatelessWidget {
  const _AlgoSelectionCard({
    required this.index,
    required this.picks,
    required this.chosen,
    required this.onToggle,
  });

  final int index;
  final List<AlgoClothPick> picks;
  final bool chosen;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final c = ds.colors;
    final ordered = [...picks]
      ..sort((a, b) => bodyOrder(a.category).compareTo(bodyOrder(b.category)));
    return Semantics(
      checked: chosen,
      child: DsPressable(
        onTap: onToggle,
        child: AnimatedContainer(
          duration: ds.motion.fast,
          padding: EdgeInsets.all(ds.space.s),
          decoration: BoxDecoration(
            color: c.bg,
            borderRadius: BorderRadius.circular(ds.shape.card),
            border: Border.all(
              color: chosen ? c.accent : c.hairline,
              width: chosen ? 2 : 1,
            ),
          ),
          child: Opacity(
            opacity: chosen ? 1 : 0.5,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${tr(context, 'result.outfitLabel')} #$index'
                            .toUpperCase(),
                        style: ds.typo.mono,
                      ),
                    ),
                    Icon(
                      chosen ? Icons.check_circle : Icons.circle_outlined,
                      color: chosen ? c.accent : c.textMuted,
                    ),
                  ],
                ),
                SizedBox(height: ds.space.xs),
                for (final p in ordered)
                  DsLayerRow(
                    index: p.role.isNotEmpty
                        ? trOr(context, 'role.${p.role}', p.role)
                        : outfitSlotLabel(context, p.category),
                    image: p.thumbUrl.isEmpty
                        ? Icon(Icons.checkroom, color: c.textMuted)
                        : AppImage(
                            url: imageUrl(p.thumbUrl),
                            fit: BoxFit.contain,
                            memWidth: 120,
                          ),
                    name: p.name,
                    note: [
                      if (p.brand.isNotEmpty) p.brand,
                      if (p.category.isNotEmpty)
                        categoryName(context, p.category),
                    ].join(' · '),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
