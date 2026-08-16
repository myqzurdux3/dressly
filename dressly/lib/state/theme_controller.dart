import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Holds the user's appearance preferences (accent color + light/dark) and
/// persists them so the choice survives restarts. Provided at the app root; the
/// MaterialApp rebuilds its themes whenever these change.
class ThemeController extends ChangeNotifier {
  static const _kSeed = 'theme_seed';
  static const _kMode = 'theme_mode';

  /// Default accent — a teal close to the app's original highlight color.
  static const Color defaultSeed = Color(0xFF14B8A6);

  /// The palette the user picks from in Settings.
  static const List<Color> presets = [
    Color(0xFF14B8A6), // teal
    Color(0xFF6366F1), // indigo
    Color(0xFF8B5CF6), // violet
    Color(0xFFEC4899), // pink
    Color(0xFFF97316), // orange
    Color(0xFF22C55E), // green
    Color(0xFF06B6D4), // cyan
    Color(0xFFEF4444), // red
    Color(0xFFEAB308), // amber
    Color(0xFF64748B), // slate
  ];

  Color _seed;
  ThemeMode _mode;

  ThemeController({
    this._seed = defaultSeed,
    this._mode = ThemeMode.dark,
  });

  Color get seed => _seed;
  ThemeMode get mode => _mode;

  static Future<ThemeController> load() async {
    final prefs = await SharedPreferences.getInstance();
    final s = prefs.getInt(_kSeed);
    return ThemeController(
      seed: s != null ? Color(s) : defaultSeed,
      mode: _modeFromString(prefs.getString(_kMode)),
    );
  }

  Future<void> setSeed(Color c) async {
    if (c.toARGB32() == _seed.toARGB32()) return;
    _seed = c;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kSeed, c.toARGB32());
  }

  Future<void> setMode(ThemeMode m) async {
    if (m == _mode) return;
    _mode = m;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kMode, m.name);
  }

  ThemeData themeFor(Brightness brightness) => ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _seed,
          brightness: brightness,
        ),
      );

  static ThemeMode _modeFromString(String? s) {
    switch (s) {
      case 'light':
        return ThemeMode.light;
      case 'system':
        return ThemeMode.system;
      default:
        return ThemeMode.dark;
    }
  }
}
