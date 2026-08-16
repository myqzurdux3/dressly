import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Holds the user's chosen app language and persists it. `null` = follow the
/// device language. Provided at the app root; MaterialApp rebuilds when it
/// changes. See [supportedLocales] for the languages we ship strings for.
class LocaleController extends ChangeNotifier {
  static const _kLang = 'app_language';

  /// Languages the app has translations for (code → display name).
  static const Map<String, String> languages = {
    'en': 'English',
    'fr': 'Français',
  };

  static const List<Locale> supportedLocales = [Locale('en'), Locale('fr')];

  Locale? _locale; // null = system default

  LocaleController([this._locale]);

  Locale? get locale => _locale;

  /// The language code actually in effect for a given context's locale.
  String get languageCode => _locale?.languageCode ?? '';

  static Future<LocaleController> load() async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString(_kLang);
    return LocaleController(
        (code != null && languages.containsKey(code)) ? Locale(code) : null);
  }

  /// Pass null to follow the device language.
  Future<void> setLanguage(String? code) async {
    final next = (code != null && languages.containsKey(code)) ? Locale(code) : null;
    if (next?.languageCode == _locale?.languageCode) return;
    _locale = next;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (next == null) {
      await prefs.remove(_kLang);
    } else {
      await prefs.setString(_kLang, next.languageCode);
    }
  }
}
