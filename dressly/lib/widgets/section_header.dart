import 'package:flutter/material.dart';

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16));
}

/// Result dialog. Lets the user step up the model cascade (flex -> pro -> max)
/// when the result is poor, generate the back view, download / enlarge, save as
/// favorite, or report to support when even pro fails.
