import 'package:flutter/material.dart';

import '../ds.dart';

/// Opens a bottom sheet in the Dressly style and returns what it pops.
Future<T?> showDsSheet<T>(
  BuildContext context, {
  required String title,
  required Widget child,
}) {
  final ds = context.ds;
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: ds.colors.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(ds.shape.hero)),
    ),
    builder: (_) => DsSheetBody(title: title, child: child),
  );
}

/// Content of a Dressly sheet: drag handle, condensed title, then [child].
/// Public so it can be shown and tested outside a modal route.
class DsSheetBody extends StatelessWidget {
  const DsSheetBody({super.key, required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        ds.space.l,
        ds.space.s,
        ds.space.l,
        ds.space.xl,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: ds.colors.hairline,
                borderRadius: ds.shape.pillRadius,
              ),
            ),
          ),
          SizedBox(height: ds.space.l),
          Text(
            title.toUpperCase(),
            style: ds.typo.headline,
            semanticsLabel: title,
          ),
          SizedBox(height: ds.space.m),
          child,
        ],
      ),
    );
  }
}
