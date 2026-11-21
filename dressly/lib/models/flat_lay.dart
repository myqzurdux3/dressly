/// Where each garment goes on the manual builder's square canvas, so an
/// outfit opens as a tidy flat lay: nothing overlapping, everything aligned
/// on a grid, each kind of garment in its place.
///
/// Reported: "tout se superpose, rien aligné, très moche". The canvas used to
/// drop every garment at one of four heights in the middle, so a t-shirt, a
/// sweatshirt and a jacket landed on top of each other, and socks under shoes.
///
/// The canvas is cut in two bands:
///   * the upper body (outer layer, mid layer, top, or a dress) side by side,
///     outermost on the left, as the eye reads an outfit;
///   * below, the bottoms on the left and a small grid on the right for shoes,
///     socks, headwear, bag and anything else.
/// A band with nothing in it gives its room to the other. Each garment is
/// fitted, centred, into its own cell, and cells never intersect.
library;

import 'dart:math' as math;

import 'layering.dart';

/// One garment's place: centre and side of its square box, as fractions of
/// the canvas side.
class FlatSlot {
  const FlatSlot(this.x, this.y, this.size);
  final double x;
  final double y;
  final double size;

  @override
  String toString() => 'FlatSlot($x, $y, $size)';
}

const _margin = 0.04;
const _gap = 0.02;

/// Fraction of a cell a garment's box fills; the rest is breathing room.
const _fill = 0.94;

enum _Group { upper, lower, small }

/// Order inside the upper band, left to right: outer, mid, top, dress.
int _upperOrder(String c) {
  final r = layerRank(c);
  if (r >= 60) return 0; // jacket, coat
  if (r >= 50) return 1; // sweatshirt, hoodie
  if (r == 35) return 3; // dress
  return 2; // tshirt, shirt, polo, tank-top
}

_Group _groupOf(String category) {
  final c = category.trim().toLowerCase();
  final r = layerRank(c);
  if (r == 30) return _Group.lower; // jeans, trousers, shorts, skirt, jogging
  if (r == 35 || (r >= 40 && r <= 62)) return _Group.upper;
  return _Group.small; // shoes, socks, hat, cap, bag, underwear, unknown
}

/// Order inside the small grid: shoes first, then socks, headwear, bag, rest.
int _smallOrder(String c) {
  final r = layerRank(c);
  if (r == 70) return 0;
  if (r == 20) return 1;
  if (r == 80) return 2;
  if (r == 90) return 3;
  return 4;
}

class _Cell {
  _Cell(this.left, this.top, this.width, this.height);
  final double left, top, width, height;

  FlatSlot fit() {
    final side = math.min(width, height) * _fill;
    return FlatSlot(left + width / 2, top + height / 2, side);
  }
}

/// [n] equal cells side by side in the box.
List<_Cell> _row(int n, double left, double top, double width, double height) {
  if (n == 0) return const [];
  final w = (width - _gap * (n - 1)) / n;
  return [
    for (var i = 0; i < n; i++) _Cell(left + i * (w + _gap), top, w, height),
  ];
}

/// [n] cells in a grid filling the box, as square as the box allows.
List<_Cell> _grid(int n, double left, double top, double width, double height) {
  if (n == 0) return const [];
  var best = 1;
  var bestSide = 0.0;
  for (var cols = 1; cols <= n; cols++) {
    final rows = (n + cols - 1) ~/ cols;
    final side = math.min(
      (width - _gap * (cols - 1)) / cols,
      (height - _gap * (rows - 1)) / rows,
    );
    if (side > bestSide) {
      bestSide = side;
      best = cols;
    }
  }
  final cols = best;
  final rows = (n + cols - 1) ~/ cols;
  final w = (width - _gap * (cols - 1)) / cols;
  final h = (height - _gap * (rows - 1)) / rows;
  return [
    for (var i = 0; i < n; i++)
      _Cell(
        left + (i % cols) * (w + _gap),
        top + (i ~/ cols) * (h + _gap),
        w,
        h,
      ),
  ];
}

/// The flat lay for these garments: cloth id -> slot. [categoryOf] gives each
/// garment's category slug ('tshirt', 'jeans', …).
Map<int, FlatSlot> flatLay(List<int> ids, String Function(int id) categoryOf) {
  final upper = <int>[], lower = <int>[], small = <int>[];
  for (final id in ids) {
    switch (_groupOf(categoryOf(id))) {
      case _Group.upper:
        upper.add(id);
      case _Group.lower:
        lower.add(id);
      case _Group.small:
        small.add(id);
    }
  }
  upper.sort(
    (a, b) => _upperOrder(categoryOf(a)).compareTo(_upperOrder(categoryOf(b))),
  );
  small.sort(
    (a, b) => _smallOrder(categoryOf(a)).compareTo(_smallOrder(categoryOf(b))),
  );

  const inner = 1 - 2 * _margin;
  final hasUpper = upper.isNotEmpty;
  final hasLower = lower.isNotEmpty || small.isNotEmpty;
  // The upper body gets a little more height: tops are the widest pieces.
  final upperH = !hasLower ? inner : (!hasUpper ? 0.0 : (inner - _gap) * 0.52);
  final lowerTop = hasUpper ? _margin + upperH + _gap : _margin;
  final lowerH = 1 - _margin - lowerTop;

  final cells = <int, _Cell>{};
  // Three or more upper pieces in one row get narrow: stack them two per row
  // only when that gives each a bigger box.
  final upperCells = upper.length >= 3
      ? _grid(upper.length, _margin, _margin, inner, upperH)
      : _row(upper.length, _margin, _margin, inner, upperH);
  for (var i = 0; i < upper.length; i++) {
    cells[upper[i]] = upperCells[i];
  }

  if (lower.isNotEmpty) {
    // Bottoms on the left, the small things in a grid on the right. Without
    // small things the bottoms take the whole band.
    final bottomsW = small.isEmpty ? inner : (inner - _gap) * 0.55;
    final lc = _row(lower.length, _margin, lowerTop, bottomsW, lowerH);
    for (var i = 0; i < lower.length; i++) {
      cells[lower[i]] = lc[i];
    }
    if (small.isNotEmpty) {
      final left = _margin + bottomsW + _gap;
      final sc = _grid(
        small.length,
        left,
        lowerTop,
        1 - _margin - left,
        lowerH,
      );
      for (var i = 0; i < small.length; i++) {
        cells[small[i]] = sc[i];
      }
    }
  } else if (small.isNotEmpty) {
    final sc = _grid(small.length, _margin, lowerTop, inner, lowerH);
    for (var i = 0; i < small.length; i++) {
      cells[small[i]] = sc[i];
    }
  }
  return {for (final e in cells.entries) e.key: e.value.fit()};
}
