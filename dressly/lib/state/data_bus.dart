import 'package:flutter/foundation.dart';

/// Tells the screens that keep their lists alive (outfits, saved, agenda,
/// wardrobe) that something changed elsewhere, so they reload instead of
/// showing a stale list. The stylist bumps it after it saves, renders or
/// edits; each screen listens while it is mounted.
class DataBus {
  DataBus._();

  static final ValueNotifier<int> outfits = ValueNotifier<int>(0);
  static final ValueNotifier<int> agenda = ValueNotifier<int>(0);
  static final ValueNotifier<int> wardrobe = ValueNotifier<int>(0);

  static void outfitsChanged() => outfits.value++;

  /// Everything the stylist may have touched in one turn.
  static void allChanged() {
    outfits.value++;
    agenda.value++;
    wardrobe.value++;
  }
}
