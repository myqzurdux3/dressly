import 'package:flutter/material.dart';

import '../ds.dart';

/// Pill-shaped search input on the surface colour: search icon, and a clear
/// button while there is text. Clearing reports `''` through [onChanged].
class DsSearchField extends StatefulWidget {
  const DsSearchField({
    super.key,
    required this.controller,
    required this.hint,
    required this.clearLabel,
    this.onChanged,
    this.onSubmitted,
  });

  static const height = 48.0;

  final TextEditingController controller;
  final String hint;
  final String clearLabel;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  @override
  State<DsSearchField> createState() => _DsSearchFieldState();
}

class _DsSearchFieldState extends State<DsSearchField> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_rebuild);
  }

  @override
  void didUpdateWidget(DsSearchField old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_rebuild);
      widget.controller.addListener(_rebuild);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final c = ds.colors;
    return Container(
      height: DsSearchField.height,
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(ds.shape.pill),
      ),
      padding: EdgeInsets.only(left: ds.space.m),
      child: Row(
        children: [
          Icon(Icons.search, color: c.textMuted),
          SizedBox(width: ds.space.s),
          Expanded(
            child: TextField(
              controller: widget.controller,
              onChanged: widget.onChanged,
              onSubmitted: widget.onSubmitted,
              textInputAction: TextInputAction.search,
              style: ds.typo.body.copyWith(color: c.text),
              cursorColor: c.accent,
              decoration: InputDecoration(
                hintText: widget.hint,
                hintStyle: ds.typo.body.copyWith(color: c.textMuted),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
                isDense: true,
              ),
            ),
          ),
          if (widget.controller.text.isNotEmpty)
            Semantics(
              button: true,
              label: widget.clearLabel,
              excludeSemantics: true,
              child: IconButton(
                onPressed: () {
                  widget.controller.clear();
                  widget.onChanged?.call('');
                },
                icon: Icon(Icons.close, color: c.textMuted),
              ),
            )
          else
            SizedBox(width: ds.space.m),
        ],
      ),
    );
  }
}
