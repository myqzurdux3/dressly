import 'dart:ui';

/// The accents the user can pick. Each one has a [base] used on fills and on
/// dark pages, and a [deep] variant used when the accent is drawn as text on a
/// light page, where [base] would be too pale to read.
enum DsAccent {
  orange(Color(0xFFFF7A3D), Color(0xFFB4471A)),
  olive(Color(0xFFA3AE62), Color(0xFF56603D)),
  brick(Color(0xFFE0583A), Color(0xFF9E3720)),
  ink(Color(0xFF6F8BFF), Color(0xFF2D45B8)),
  acid(Color(0xFFD7FF3A), Color(0xFF5E7300));

  const DsAccent(this.base, this.deep);

  final Color base;
  final Color deep;

  /// Parses a persisted name; anything unknown (including accents from older
  /// versions of the app) falls back to [orange].
  static DsAccent fromName(String? name) =>
      values.where((a) => a.name == name).firstOrNull ?? orange;
}
