import 'package:flutter/material.dart';

import '../ds.dart';

enum DsButtonKind { primary, secondary, icon }

/// Pill button. `onPressed == null` disables it; [loading] shows a spinner and
/// swallows taps so an action cannot be fired twice.
class DsButton extends StatelessWidget {
  const DsButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.kind = DsButtonKind.primary,
    this.icon,
    this.expand = false,
    this.loading = false,
  }) : semanticLabel = null;

  /// Round icon-only button; [semanticLabel] is what screen readers announce.
  const DsButton.icon({
    super.key,
    required IconData this.icon,
    required String this.semanticLabel,
    required this.onPressed,
  }) : label = '',
       kind = DsButtonKind.icon,
       expand = false,
       loading = false;

  static const double height = 52;

  final String label;
  final VoidCallback? onPressed;
  final DsButtonKind kind;
  final IconData? icon;
  final bool expand;
  final bool loading;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final c = ds.colors;
    final (fill, ink) = switch (kind) {
      DsButtonKind.primary => (c.accent, c.onAccent),
      DsButtonKind.secondary || DsButtonKind.icon => (c.surface, c.text),
    };
    final enabled = onPressed != null && !loading;

    final Widget content;
    if (loading) {
      content = SizedBox.square(
        dimension: 20,
        child: CircularProgressIndicator(strokeWidth: 2.4, color: ink),
      );
    } else if (kind == DsButtonKind.icon) {
      content = Icon(icon, color: ink, size: 22);
    } else {
      content = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, color: ink, size: 20),
            SizedBox(width: ds.space.s),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ds.typo.title.copyWith(color: ink),
            ),
          ),
        ],
      );
    }

    final button = Semantics(
      button: true,
      enabled: enabled,
      label: semanticLabel,
      excludeSemantics: semanticLabel != null,
      child: Opacity(
        opacity: onPressed == null ? 0.4 : 1,
        child: Material(
          color: fill,
          // Secondary buttons share their fill with cards and dialogs; the
          // hairline keeps them reading as buttons there, not as links.
          shape: kind == DsButtonKind.primary
              ? const StadiumBorder()
              : StadiumBorder(side: BorderSide(color: c.hairline)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: enabled ? onPressed : null,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: height,
                minWidth: height,
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: kind == DsButtonKind.icon ? 0 : ds.space.xl,
                ),
                child: Center(widthFactor: 1, heightFactor: 1, child: content),
              ),
            ),
          ),
        ),
      ),
    );
    return expand ? SizedBox(width: double.infinity, child: button) : button;
  }
}
