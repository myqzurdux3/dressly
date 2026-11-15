import 'package:flutter/material.dart';

import 'accent.dart';
import 'tokens.dart';

/// A complete Dressly look. Adding a theme means implementing this, not
/// touching screens: components read everything from [DsTokens].
abstract class DsTheme {
  /// Stable identifier, persisted when the user picks a theme.
  String get id;

  DsTokens tokens(Brightness brightness, DsAccent accent);

  /// The Material theme carrying [tokens] as an extension, so widgets not yet
  /// migrated to the design system still pick up the right colours.
  ThemeData themeData(Brightness brightness, DsAccent accent);
}
