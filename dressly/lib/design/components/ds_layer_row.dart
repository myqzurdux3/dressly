import 'package:flutter/material.dart';

import '../ds.dart';

/// One layer of an outfit, outermost first: "L3·EXT  [photo]  DOUDOUNE NOIRE
/// / imperméable".
class DsLayerRow extends StatelessWidget {
  const DsLayerRow({
    super.key,
    required this.index,
    required this.image,
    required this.name,
    this.note,
  });

  final String index;
  final Widget image;
  final String name;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final c = ds.colors;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: ds.space.xs + 2),
      child: Row(
        children: [
          SizedBox(
            width: 64,
            // One line, shrunk if needed: "ACCESSORY" broke as "ACCESSOR/Y".
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                index.toUpperCase(),
                maxLines: 1,
                style: ds.typo.monoSmall.copyWith(color: c.accentText),
              ),
            ),
          ),
          Container(
            width: 54,
            height: 54,
            padding: EdgeInsets.all(ds.space.s),
            decoration: BoxDecoration(
              color: c.surfaceHigh,
              borderRadius: ds.shape.smallRadius,
            ),
            child: FittedBox(child: image),
          ),
          SizedBox(width: ds.space.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ds.typo.bodyStrong,
                ),
                if (note != null)
                  Text(
                    note!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ds.typo.monoSmall,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
