import 'package:flutter/material.dart';

/// Backgrounds the user can lay a manual outfit on. These are content (they
/// end up in the saved image), not app chrome, so they do not follow the
/// theme; they live here so screens stay free of literal colours.
const Color kCanvasDefault = Colors.white;

const List<Color> kCanvasSwatches = [
  Colors.white,
  Color(0xFFF2EDE4),
  Color(0xFFD9D9D9),
  Color(0xFF9E9E9E),
  Color(0xFF4A4A4A),
  Colors.black,
  Color(0xFFEED9C4),
  Color(0xFFD7B899),
  Color(0xFFF7C5CC),
  Color(0xFFF6A6B2),
  Color(0xFFF3D250),
  Color(0xFFF0A04B),
  Color(0xFFA8D5BA),
  Color(0xFF6DBF9C),
  Color(0xFF9FB4E8),
  Color(0xFF5C7AEA),
  Color(0xFFC9A7EB),
  Color(0xFF8E6BC4),
];

const List<List<Color>> kCanvasGradients = [
  [Color(0xFFFBC2EB), Color(0xFFA6C1EE)],
  [Color(0xFFFDCB82), Color(0xFFF3777A)],
  [Color(0xFFA8EDEA), Color(0xFFFED6E3)],
  [Color(0xFFD4FC79), Color(0xFF96E6A1)],
  [Color(0xFFE0C3FC), Color(0xFF8EC5FC)],
  [Color(0xFFF5F7FA), Color(0xFFC3CFE2)],
  [Color(0xFF434343), Color(0xFF000000)],
];
