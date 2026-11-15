import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../design/ds.dart';

/// Holds the user's appearance preferences (accent + light/dark) and persists
/// them so the choice survives restarts. Provided at the app root; the
/// MaterialApp rebuilds its themes whenever these change.
class ThemeController extends ChangeNotifier {
  static const _kAccent = 'theme_accent';
  static const _kMode = 'theme_mode';

  /// Accent colour of the pre-redesign app; dropped on load.
  static const _kLegacySeed = 'theme_seed';

  static const DsTheme _theme = ThemeF();

  DsAccent _accent;
  ThemeMode _mode;

  ThemeController({
    this._accent = DsAccent.orange,
    this._mode = ThemeMode.dark,
  });

  DsAccent get accent => _accent;
  ThemeMode get mode => _mode;

  static Future<ThemeController> load() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.containsKey(_kLegacySeed)) await prefs.remove(_kLegacySeed);
    return ThemeController(
      accent: DsAccent.fromName(prefs.getString(_kAccent)),
      mode: _modeFromString(prefs.getString(_kMode)),
    );
  }

  Future<void> setAccent(DsAccent a) async {
    if (a == _accent) return;
    _accent = a;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kAccent, a.name);
  }

  Future<void> setMode(ThemeMode m) async {
    if (m == _mode) return;
    _mode = m;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kMode, m.name);
  }

  ThemeData themeFor(Brightness brightness) =>
      _theme.themeData(brightness, _accent);

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
