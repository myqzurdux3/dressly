import 'package:flutter/material.dart';

import 'accent.dart';
import 'ds_theme.dart';
import 'tokens.dart';

/// Theme F, "Étiquette × Atelier": dark chocolate and cream, giant condensed
/// titles (Anton), warm rounded cards, mono metadata (IBM Plex Mono).
class ThemeF implements DsTheme {
  const ThemeF();

  static const ink = Color(0xFF17120F);
  static const cream = Color(0xFFF1E6D6);

  @override
  String get id => 'f';

  @override
  DsTokens tokens(Brightness brightness, DsAccent accent) {
    final colors = _colors(brightness, accent);
    return DsTokens(
      colors: colors,
      typo: _type(colors),
      shape: const DsShape(small: 10, card: 20, hero: 26, pill: 999),
      space: const DsSpace(
        xs: 4,
        s: 8,
        m: 12,
        l: 16,
        xl: 24,
        xxl: 32,
        gutter: 12,
      ),
      motion: const DsMotion(
        fast: Duration(milliseconds: 150),
        base: Duration(milliseconds: 220),
        slow: Duration(milliseconds: 320),
        standard: Curves.easeOutCubic,
        press: SpringDescription(mass: 1, stiffness: 380, damping: 26),
      ),
    );
  }

  @override
  ThemeData themeData(Brightness brightness, DsAccent accent) {
    final t = tokens(brightness, accent);
    final c = t.colors;
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      fontFamily: DsFonts.body,
      scaffoldBackgroundColor: c.bg,
      colorScheme: ColorScheme(
        brightness: brightness,
        primary: c.accent,
        onPrimary: c.onAccent,
        secondary: c.olive,
        onSecondary: cream,
        error: c.danger,
        onError: cream,
        surface: c.bg,
        onSurface: c.text,
        onSurfaceVariant: c.textMuted,
        outline: c.textMuted,
        outlineVariant: c.hairline,
        surfaceContainerLowest: c.bg,
        surfaceContainerLow: c.surface,
        surfaceContainer: c.surface,
        surfaceContainerHigh: c.surfaceHigh,
        surfaceContainerHighest: c.surfaceHigh,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: c.surface,
        indicatorColor: c.accent,
        labelTextStyle: WidgetStatePropertyAll(t.typo.label),
        iconTheme: WidgetStateProperty.resolveWith(
          (s) => IconThemeData(
            color: s.contains(WidgetState.selected) ? c.onAccent : c.textMuted,
          ),
        ),
      ),
      extensions: [t],
    );
  }

  static DsColors _colors(Brightness brightness, DsAccent accent) {
    final onAccent = _bestOn(accent.base);
    return switch (brightness) {
      Brightness.dark => DsColors(
        bg: ink,
        surface: const Color(0xFF2A221C),
        surfaceHigh: const Color(0xFF362C24),
        text: cream,
        textMuted: const Color(0xFF9A8877),
        hairline: const Color(0xFF3A3029),
        accent: accent.base,
        onAccent: onAccent,
        accentText: accent.base,
        olive: const Color(0xFF56603D),
        danger: const Color(0xFFFF5A4E),
      ),
      Brightness.light => DsColors(
        bg: cream,
        surface: const Color(0xFFE6D8C4),
        surfaceHigh: const Color(0xFFDCCBB3),
        text: ink,
        textMuted: const Color(0xFF6E5B4A),
        hairline: const Color(0xFFD3C0A6),
        accent: accent.base,
        onAccent: onAccent,
        accentText: accent.deep,
        olive: const Color(0xFF56603D),
        danger: const Color(0xFFB3261E),
      ),
    };
  }

  /// Ink or cream, whichever contrasts more with [fill] (WCAG ratio).
  static Color _bestOn(Color fill) {
    double ratio(Color a, Color b) {
      final la = a.computeLuminance(), lb = b.computeLuminance();
      return la > lb ? (la + 0.05) / (lb + 0.05) : (lb + 0.05) / (la + 0.05);
    }

    return ratio(ink, fill) >= ratio(cream, fill) ? ink : cream;
  }

  static DsType _type(DsColors c) {
    TextStyle bricolage(double size, double weight, {Color? color}) =>
        TextStyle(
          fontFamily: DsFonts.body,
          fontSize: size,
          fontWeight: FontWeight.values[(weight ~/ 100) - 1],
          fontVariations: [FontVariation.weight(weight)],
          color: color ?? c.text,
        );
    TextStyle mono(double size, FontWeight weight) => TextStyle(
      fontFamily: DsFonts.mono,
      fontSize: size,
      fontWeight: weight,
      letterSpacing: 0.5,
      color: c.textMuted,
    );
    return DsType(
      display: TextStyle(
        fontFamily: DsFonts.display,
        fontSize: 56,
        height: 0.85,
        color: c.text,
      ),
      headline: TextStyle(
        fontFamily: DsFonts.display,
        fontSize: 26,
        height: 1,
        color: c.text,
      ),
      title: bricolage(18, 700),
      body: bricolage(15, 400),
      bodyStrong: bricolage(15, 600),
      label: bricolage(12, 600),
      mono: mono(11, FontWeight.w500),
      monoSmall: mono(9, FontWeight.w400),
    );
  }
}

/// Font family names as declared in pubspec.yaml.
abstract final class DsFonts {
  static const display = 'Anton';
  static const body = 'Bricolage';
  static const mono = 'PlexMono';
}
