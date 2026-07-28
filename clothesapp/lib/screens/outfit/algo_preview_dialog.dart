import 'package:flutter/material.dart';

import '../../config/api_config.dart';
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
          SnackBar(content: Text('${tr(context, 'result.reshuffleFailed')}: $e')),
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
        if (_chosen.contains(i)) _preview.selections[i]
    ];
    Navigator.pop(
        context,
        AlgoPreview(
            algo: _preview.algo,
            algoLabel: _preview.algoLabel,
            selections: chosen));
  }

  @override
  Widget build(BuildContext context) {
    final n = _preview.selections.length;
    final k = _chosen.length;
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 720),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_preview.algoLabel,
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.bold)),
                      Text(
                          tr(context, 'algo.proposed')
                              .replaceFirst('{n}', '$n'),
                          style:
                              const TextStyle(color: Colors.white70, fontSize: 12)),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context, null),
                ),
              ]),
              const SizedBox(height: 4),
              Text(tr(context, 'algo.pickWhich'),
                  style: const TextStyle(color: Colors.grey, fontSize: 12)),
              const SizedBox(height: 12),
              Flexible(
                child: _reshuffling
                    ? const Center(child: CircularProgressIndicator())
                    : ListView.separated(
                        shrinkWrap: true,
                        itemCount: n,
                        separatorBuilder: (_, __) => const Divider(height: 24),
                        itemBuilder: (context, i) {
                          final sel = _preview.selections[i];
                          final on = _chosen.contains(i);
                          return InkWell(
                            onTap: () => setState(() {
                              if (on) {
                                _chosen.remove(i);
                              } else {
                                _chosen.add(i);
                              }
                            }),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Checkbox(
                                  value: on,
                                  onChanged: (v) => setState(() {
                                    if (v == true) {
                                      _chosen.add(i);
                                    } else {
                                      _chosen.remove(i);
                                    }
                                  }),
                                ),
                                Expanded(
                                  child: _AlgoSelectionCard(
                                      index: i + 1, picks: sel),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _reshuffling ? null : _doReshuffle,
                    icon: const Icon(Icons.refresh),
                    label: Text(tr(context, 'result.reshuffle')),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: (_reshuffling || k == 0) ? null : _confirm,
                    icon: const Icon(Icons.auto_awesome),
                    label: Text('${tr(context, 'result.generate')} $k ${trPlural(context, 'result.outfit', k)}'),
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

class _AlgoSelectionCard extends StatelessWidget {
  const _AlgoSelectionCard({required this.index, required this.picks});
  final int index;
  final List<AlgoClothPick> picks;

  @override
  Widget build(BuildContext context) {
    // Order head-to-toe: tops first, shoes last.
    final ordered = [...picks]
      ..sort((a, b) => bodyOrder(a.category).compareTo(bodyOrder(b.category)));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('${tr(context, 'result.outfitLabel')} #$index',
          style:
              const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
      const SizedBox(height: 8),
      ...ordered.map((c) => Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: c.thumbUrl.isEmpty
                    ? Container(
                        width: 44,
                        height: 44,
                        color: Colors.blueGrey.shade900,
                        child: const Icon(Icons.checkroom,
                            color: Colors.white38, size: 20),
                      )
                    : SizedBox(
                        width: 44,
                        height: 44,
                        child: AppImage(
                          url: imageUrl(c.thumbUrl),
                          fit: BoxFit.contain,
                          memWidth: 88,
                        ),
                      ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(c.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w500)),
                    Text(
                      [
                        if (c.role.isNotEmpty) c.role,
                        if (c.brand.isNotEmpty) c.brand,
                        if (c.category.isNotEmpty) c.category,
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white60, fontSize: 11),
                    ),
                  ],
                ),
              ),
            ]),
          )),
    ]);
  }
}

/// Chip with a name (tap to open the cloth's detail page) and an X (tap to
/// remove the cloth from the outfit and re-render). Replaces InputChip so
/// tap and delete don't share a single gesture handler.
