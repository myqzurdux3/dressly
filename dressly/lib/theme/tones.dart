import 'package:flutter/material.dart';

/// Foreground tones that follow the active theme.
///
/// The app was written dark-first, with literal `Colors.white70` / `white54` /
/// `white38` standing in for "secondary text". Those are invisible on the light
/// theme's background: brand names, the category and cut chips, the "never
/// worn" line and the wardrobe counter all disappeared on a white page, so the
/// light theme shipped unusable while looking fine in every screenshot taken in
/// the dark one.
///
/// Material's scheme already carries the right value for each brightness; these
/// helpers name them so a call site reads as intent rather than as a colour.
///
/// Text drawn ON a photo or a dark scrim keeps its literal white: it is white
/// because of what sits behind it, not because of the theme.
Color secondaryText(BuildContext context) =>
    Theme.of(context).colorScheme.onSurfaceVariant;

/// One step fainter than [secondaryText]: hints, disabled marks, empty stars.
Color faintText(BuildContext context) => Theme.of(context).colorScheme.outline;

/// Borders that should read as a hairline rather than as a frame.
Color hairline(BuildContext context) =>
    Theme.of(context).colorScheme.outlineVariant;

/// The wash behind a small chip or pill sitting directly on the page.
Color subtleFill(BuildContext context) =>
    Theme.of(context).colorScheme.surfaceContainerHighest;
