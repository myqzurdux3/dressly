import 'package:flutter/material.dart';

import '../ds.dart';

/// A screen reached from another one: back button (plus [actions]), a
/// headline title, then [children] in a padded scrolling column.
class DsSubPage extends StatelessWidget {
  const DsSubPage({
    super.key,
    required this.title,
    required this.children,
    this.actions = const [],
    this.onRefresh,
    this.bottom,
  });

  final String title;
  final List<Widget> children;
  final List<Widget> actions;
  final Future<void> Function()? onRefresh;

  /// Pinned under the list (e.g. a submit button).
  final Widget? bottom;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    Widget list = ListView(
      padding: EdgeInsets.fromLTRB(
        ds.space.gutter,
        0,
        ds.space.gutter,
        ds.space.xl,
      ),
      children: [
        Padding(
          padding: EdgeInsets.only(top: ds.space.m, bottom: ds.space.s),
          child: Text(title.toUpperCase(), style: ds.typo.display),
        ),
        ...children,
      ],
    );
    if (onRefresh != null) {
      list = RefreshIndicator(
        color: ds.colors.accent,
        onRefresh: onRefresh!,
        child: list,
      );
    }
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                ds.space.gutter,
                ds.space.s,
                ds.space.gutter,
                0,
              ),
              child: Row(
                children: [
                  DsButton.icon(
                    icon: Icons.arrow_back,
                    semanticLabel: MaterialLocalizations.of(
                      context,
                    ).backButtonTooltip,
                    onPressed: () => Navigator.maybePop(context),
                  ),
                  const Spacer(),
                  for (final (i, a) in actions.indexed) ...[
                    if (i > 0) SizedBox(width: ds.space.xs),
                    a,
                  ],
                ],
              ),
            ),
            Expanded(child: list),
            if (bottom != null)
              Padding(
                padding: EdgeInsets.fromLTRB(
                  ds.space.gutter,
                  ds.space.s,
                  ds.space.gutter,
                  ds.space.m,
                ),
                child: bottom,
              ),
          ],
        ),
      ),
    );
  }
}

/// One line of information on a surface card: icon, title, optional detail,
/// optional trailing widget. Tappable when [onTap] is given (adds a chevron
/// unless [trailing] is set).
class DsInfoRow extends StatelessWidget {
  const DsInfoRow({
    super.key,
    required this.icon,
    required this.title,
    this.detail,
    this.trailing,
    this.onTap,
    this.danger = false,
    this.color,
  });

  final IconData icon;
  final String title;
  final String? detail;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool danger;

  /// Card fill; null is the surface colour.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final c = ds.colors;
    final ink = danger ? c.danger : c.text;
    final row = Container(
      padding: EdgeInsets.all(ds.space.m),
      decoration: BoxDecoration(
        color: color ?? c.surface,
        borderRadius: ds.shape.cardRadius,
      ),
      child: Row(
        children: [
          Icon(icon, color: danger ? c.danger : c.accentText),
          SizedBox(width: ds.space.s),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: ds.typo.bodyStrong.copyWith(color: ink)),
                if (detail != null && detail!.isNotEmpty)
                  Text(
                    detail!,
                    style: ds.typo.label.copyWith(color: c.textMuted),
                  ),
              ],
            ),
          ),
          if (trailing != null)
            trailing!
          else if (onTap != null && !danger)
            Icon(Icons.chevron_right, color: c.textMuted),
        ],
      ),
    );
    return Padding(
      padding: EdgeInsets.only(bottom: ds.space.xs),
      child: onTap == null ? row : DsPressable(onTap: onTap, child: row),
    );
  }
}
