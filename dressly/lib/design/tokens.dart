import 'package:flutter/material.dart';

/// Colour roles. Screens pick a role, never a literal colour, so a theme can
/// repaint the whole app by providing another [DsColors].
@immutable
class DsColors {
  const DsColors({
    required this.bg,
    required this.surface,
    required this.surfaceHigh,
    required this.text,
    required this.textMuted,
    required this.hairline,
    required this.accent,
    required this.onAccent,
    required this.accentText,
    required this.olive,
    required this.danger,
  });

  /// Page background.
  final Color bg;

  /// Cards, sheets, the tab bar.
  final Color surface;

  /// A surface sitting on a surface (pressed card, input on a sheet).
  final Color surfaceHigh;
  final Color text;

  /// Secondary text: metadata, hints, inactive labels.
  final Color textMuted;

  /// Separators that should read as a line, not a frame.
  final Color hairline;

  /// Fills: primary button, active tab, selected chip.
  final Color accent;

  /// Text and icons drawn on [accent].
  final Color onAccent;

  /// The accent when drawn as text on [bg].
  final Color accentText;
  final Color olive;
  final Color danger;

  DsColors lerp(DsColors o, double t) => DsColors(
    bg: Color.lerp(bg, o.bg, t)!,
    surface: Color.lerp(surface, o.surface, t)!,
    surfaceHigh: Color.lerp(surfaceHigh, o.surfaceHigh, t)!,
    text: Color.lerp(text, o.text, t)!,
    textMuted: Color.lerp(textMuted, o.textMuted, t)!,
    hairline: Color.lerp(hairline, o.hairline, t)!,
    accent: Color.lerp(accent, o.accent, t)!,
    onAccent: Color.lerp(onAccent, o.onAccent, t)!,
    accentText: Color.lerp(accentText, o.accentText, t)!,
    olive: Color.lerp(olive, o.olive, t)!,
    danger: Color.lerp(danger, o.danger, t)!,
  );
}

/// Text roles. Colours are baked in from a [DsColors] so a style is usable
/// as-is; override with `copyWith(color: ...)` only for a different role.
@immutable
class DsType {
  const DsType({
    required this.display,
    required this.headline,
    required this.title,
    required this.body,
    required this.bodyStrong,
    required this.label,
    required this.mono,
    required this.monoSmall,
  });

  /// Giant condensed screen titles, written in capitals.
  final TextStyle display;

  /// Condensed section and card titles.
  final TextStyle headline;
  final TextStyle title;
  final TextStyle body;
  final TextStyle bodyStrong;

  /// Chips, buttons, tab labels.
  final TextStyle label;

  /// Metadata: counts, dates, temperatures.
  final TextStyle mono;
  final TextStyle monoSmall;

  DsType lerp(DsType o, double t) => DsType(
    display: TextStyle.lerp(display, o.display, t)!,
    headline: TextStyle.lerp(headline, o.headline, t)!,
    title: TextStyle.lerp(title, o.title, t)!,
    body: TextStyle.lerp(body, o.body, t)!,
    bodyStrong: TextStyle.lerp(bodyStrong, o.bodyStrong, t)!,
    label: TextStyle.lerp(label, o.label, t)!,
    mono: TextStyle.lerp(mono, o.mono, t)!,
    monoSmall: TextStyle.lerp(monoSmall, o.monoSmall, t)!,
  );
}

@immutable
class DsShape {
  const DsShape({
    required this.small,
    required this.card,
    required this.hero,
    required this.pill,
  });

  final double small;
  final double card;
  final double hero;

  /// Fully rounded ends (chips, buttons, the tab bar).
  final double pill;

  BorderRadius get smallRadius => BorderRadius.circular(small);
  BorderRadius get cardRadius => BorderRadius.circular(card);
  BorderRadius get heroRadius => BorderRadius.circular(hero);
  BorderRadius get pillRadius => BorderRadius.circular(pill);
}

@immutable
class DsSpace {
  const DsSpace({
    required this.xs,
    required this.s,
    required this.m,
    required this.l,
    required this.xl,
    required this.xxl,
    required this.gutter,
  });

  final double xs;
  final double s;
  final double m;
  final double l;
  final double xl;
  final double xxl;

  /// Horizontal page padding.
  final double gutter;
}

@immutable
class DsMotion {
  const DsMotion({
    required this.fast,
    required this.base,
    required this.slow,
    required this.standard,
    required this.press,
  });

  final Duration fast;
  final Duration base;
  final Duration slow;
  final Curve standard;

  /// Spring used when a card is pressed and released.
  final SpringDescription press;
}

/// Every design token of the active theme, reachable with `context.ds`.
///
/// Colours and text styles interpolate during a theme animation; shape,
/// spacing and motion switch at the midpoint since a half-way radius or
/// duration means nothing.
@immutable
class DsTokens extends ThemeExtension<DsTokens> {
  const DsTokens({
    required this.colors,
    required this.typo,
    required this.shape,
    required this.space,
    required this.motion,
  });

  final DsColors colors;
  final DsType typo;
  final DsShape shape;
  final DsSpace space;
  final DsMotion motion;

  @override
  DsTokens copyWith({
    DsColors? colors,
    DsType? typo,
    DsShape? shape,
    DsSpace? space,
    DsMotion? motion,
  }) => DsTokens(
    colors: colors ?? this.colors,
    typo: typo ?? this.typo,
    shape: shape ?? this.shape,
    space: space ?? this.space,
    motion: motion ?? this.motion,
  );

  @override
  DsTokens lerp(covariant DsTokens? other, double t) {
    if (other == null) return this;
    final snap = t < 0.5 ? this : other;
    return DsTokens(
      colors: colors.lerp(other.colors, t),
      typo: typo.lerp(other.typo, t),
      shape: snap.shape,
      space: snap.space,
      motion: snap.motion,
    );
  }
}
