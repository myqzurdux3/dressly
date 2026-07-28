import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// User preference for outfit-generation quality, persisted on the device.
///
/// When [highQualityOnly] is on, a fresh render skips the fast tiers (flex and
/// the VTO try-on) and uses only the premium FLUX models: pro -> max. Off
/// (the default) keeps the full cascade flex -> vto -> pro -> max.
///
/// This is enforced entirely by the starting tier we request: the backend
/// honours an explicit `pro` start and cascades pro -> max from there.
class GenPrefsController extends ChangeNotifier {
  static const _kHqOnly = 'gen_high_quality_only';

  bool _highQualityOnly;

  GenPrefsController([this._highQualityOnly = false]);

  bool get highQualityOnly => _highQualityOnly;

  /// The starting tier to request for a fresh outfit render. 'pro' skips flex +
  /// vto (pro -> max); 'flex' is the normal full cascade.
  String get startTier => _highQualityOnly ? 'pro' : 'flex';

  static Future<GenPrefsController> load() async {
    final prefs = await SharedPreferences.getInstance();
    return GenPrefsController(prefs.getBool(_kHqOnly) ?? false);
  }

  Future<void> setHighQualityOnly(bool value) async {
    if (value == _highQualityOnly) return;
    _highQualityOnly = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kHqOnly, value);
  }
}
