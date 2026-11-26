import 'package:flutter/material.dart';

import '../ds.dart';

/// Screen title: two giant condensed lines, the second in the accent, with
/// mono metadata stacked on the right ("87 PIÈCES / +3 CE MOIS").
class DsHeader extends StatelessWidget {
  const DsHeader({
    super.key,
    required this.line1,
    required this.line2,
    this.meta = const [],
    this.trailing,
  });

  final String line1;
  final String line2;
  final List<String> meta;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    Widget line(String text, Color color) => FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Text(
        text.toUpperCase(),
        maxLines: 1,
        style: ds.typo.display.copyWith(color: color),
      ),
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(
        ds.space.gutter,
        ds.space.l,
        ds.space.gutter,
        ds.space.m,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Semantics(
              header: true,
              label: '$line1 $line2',
              excludeSemantics: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  line(line1, ds.colors.text),
                  line(line2, ds.colors.accentText),
                ],
              ),
            ),
          ),
          if (trailing != null || meta.isNotEmpty) ...[
            SizedBox(width: ds.space.m),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                ?trailing,
                for (final m in meta)
                  Text(
                    m.toUpperCase(),
                    textAlign: TextAlign.right,
                    style: ds.typo.mono,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
