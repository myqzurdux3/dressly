import 'package:flutter/material.dart';

/// Colours used to present a garment as a fabric swatch: [fill] behind the
/// photo, [shade] for its silhouette or placeholder, [onFill] for text.
@immutable
class GarmentTone {
  const GarmentTone(this.fill, this.shade, this.onFill);

  final Color fill;
  final Color shade;
  final Color onFill;

  @override
  bool operator ==(Object other) =>
      other is GarmentTone &&
      other.fill == fill &&
      other.shade == shade &&
      other.onFill == onFill;

  @override
  int get hashCode => Object.hash(fill, shade, onFill);
}

const _ink = Color(0xFF17120F);
const _cream = Color(0xFFF1E6D6);

/// Muted takes on the palette colours, so a grid of garments reads as one
/// collection rather than as a box of crayons.
const _tones = <String, GarmentTone>{
  'black': GarmentTone(Color(0xFF36322F), Color(0xFF0E0C0B), _cream),
  'white': GarmentTone(Color(0xFFF4EFE6), Color(0xFFC9BEAC), _ink),
  'grey': GarmentTone(Color(0xFF6B6661), Color(0xFF4A4642), _cream),
  'blue': GarmentTone(Color(0xFF3D4A5C), Color(0xFF1F2836), _cream),
  'red': GarmentTone(Color(0xFFB23A2E), Color(0xFF7A2018), _cream),
  'green': GarmentTone(Color(0xFF56603D), Color(0xFF3A4228), _cream),
  'yellow': GarmentTone(Color(0xFFE3C24A), Color(0xFFB8962A), _ink),
  'beige': GarmentTone(Color(0xFFE8DCC4), Color(0xFFCBB894), _ink),
  'brown': GarmentTone(Color(0xFF6B4A33), Color(0xFF4A3020), _cream),
  'orange': GarmentTone(Color(0xFFFF7A3D), Color(0xFFC2501D), _ink),
  'purple': GarmentTone(Color(0xFF5E4A6E), Color(0xFF3C2C4A), _cream),
  'pink': GarmentTone(Color(0xFFE8A0B4), Color(0xFFC47088), _ink),
};

const _neutralDark = GarmentTone(Color(0xFF2A221C), Color(0xFF4A3E34), _cream);
const _neutralLight = GarmentTone(Color(0xFFE6D8C4), Color(0xFFC2AF94), _ink);

/// Tone for a garment colour name as stored by the backend (`kColorPalette`).
/// Unknown or empty names get the page's neutral surface tone.
GarmentTone garmentTone(String colorName, Brightness brightness) {
  var key = colorName.trim().toLowerCase();
  if (key == 'gray') key = 'grey';
  return _tones[key] ??
      (brightness == Brightness.dark ? _neutralDark : _neutralLight);
}
