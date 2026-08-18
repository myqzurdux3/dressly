import 'package:flutter/material.dart';

/// The Dressly logo, direction "2a" from the logo canvas: a dark rounded tile
/// holding an extra-bold "d" with a mint dot in the corner, next to the
/// wordmark.
///
/// The colors are deliberately NOT taken from the theme seed: the user can
/// repaint the whole app from Settings, and a brand mark that changes color
/// with the accent stops being a brand mark. Only the wordmark flips with the
/// surface brightness, so it stays readable in the light theme.
class BrandColors {
  const BrandColors._();

  /// Tile fill and its hairline border.
  static const Color tile = Color(0xFF1C211F);
  static const Color tileBorder = Color(0xFF2E3532);

  /// The accent: mint. Used for the dot and nothing else.
  static const Color mint = Color(0xFF7DDCC8);

  /// Wordmark on a dark surface, and the "d" inside the tile.
  static const Color light = Color(0xFFEEF1EF);

  /// Wordmark on a light surface.
  static const Color dark = Color(0xFF0D0F0F);

  /// Wordmark color for the surface it sits on.
  static Color textFor(Brightness b) => b == Brightness.dark ? light : dark;
}

const String _brandFont = 'Manrope';

/// Below this tile size the corner dot is dropped: at 32px and under it stops
/// reading as a dot and just dirties the corner (the artboard drops it too).
const double _kDotMinSize = 34;

/// The wordmark: "dressly" in the brand grotesque.
///
/// [compact] switches to the app-bar form from the artboard — "Dressly",
/// one weight down and less tightly tracked, which is what survives at 20px.
class DresslyWordmark extends StatelessWidget {
  const DresslyWordmark({
    super.key,
    this.size = 28,
    this.color,
    this.compact = false,
  });

  /// Font size of the wordmark in logical pixels.
  final double size;

  /// Overrides the wordmark color. Defaults to the one for the brightness.
  final Color? color;

  /// Use the app-bar form rather than the display form.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final fg = color ?? BrandColors.textFor(Theme.of(context).brightness);
    return Text(
      compact ? 'Dressly' : 'dressly',
      style: TextStyle(
        fontFamily: _brandFont,
        fontWeight: compact ? FontWeight.w700 : FontWeight.w800,
        fontSize: size,
        height: 1.1, // room for the descender of "y"
        letterSpacing: size * (compact ? -0.02 : -0.045),
        color: fg,
      ),
    );
  }
}

/// The monogram: the rounded tile with the "d" and the mint dot. This is the
/// app-icon form of the logo.
///
/// Everything scales off [size] with the ratios of the 2a artboard, so the
/// 86px lockup and the 30px app-bar mark are the same drawing, not two
/// hand-tuned ones.
class DresslyMonogram extends StatelessWidget {
  const DresslyMonogram({
    super.key,
    this.size = 86,
    this.background,
    this.foreground,
    this.showDot,
    this.showBorder = true,
  });

  /// Side of the (square) tile.
  final double size;

  final Color? background;
  final Color? foreground;

  /// Forces the corner dot on or off. Defaults to on above [_kDotMinSize].
  final bool? showDot;

  /// The hairline border. Off for the launcher icon, where the tile is
  /// already separated from everything by the launcher's own mask.
  final bool showBorder;

  @override
  Widget build(BuildContext context) {
    final bg = background ?? BrandColors.tile;
    final fg = foreground ?? BrandColors.light;
    final dot = size * 0.105;
    final withDot = showDot ?? size >= _kDotMinSize;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          Container(
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(size * 0.302),
              border: showBorder
                  ? Border.all(color: BrandColors.tileBorder, width: 1)
                  : null,
            ),
            alignment: Alignment.center,
            // The "d" has no descender, so a line box centred on the tile
            // parks the glyph low; lift it back to the optical centre.
            child: Transform.translate(
              offset: Offset(0, -size * 0.035),
              child: Text(
                'd',
                style: TextStyle(
                  fontFamily: _brandFont,
                  fontWeight: FontWeight.w800,
                  // 50px glyph inside an 86px tile on the artboard.
                  fontSize: size * 0.581,
                  height: 1,
                  letterSpacing: size * -0.04,
                  color: fg,
                ),
              ),
            ),
          ),
          if (withDot)
            Positioned(
              top: size * 0.198,
              right: size * 0.198,
              child: Container(
                width: dot,
                height: dot,
                decoration: const BoxDecoration(
                  color: BrandColors.mint,
                  shape: BoxShape.circle,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Tile + wordmark side by side, the way the artboard pairs them.
class DresslyLockup extends StatelessWidget {
  const DresslyLockup({
    super.key,
    this.tileSize = 86,
    this.wordmarkSize = 46,
    this.compact = false,
  });

  final double tileSize;
  final double wordmarkSize;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        DresslyMonogram(size: tileSize),
        SizedBox(width: tileSize * 0.23),
        DresslyWordmark(size: wordmarkSize, compact: compact),
      ],
    );
  }
}
