import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every colour, text style, radius and animation duration comes from the
/// design system (`lib/design/`). Files written before the redesign are listed
/// in `design_guard_legacy.txt`; that list may only shrink. Once a screen is
/// migrated it must leave the list, which this test enforces too.

const _legacyListPath = 'test/design_guard_legacy.txt';

final _patterns = <RegExp>[
  RegExp(r'Color\(0x'),
  RegExp(r'Colors\.(?!transparent\b)'),
  RegExp(r'TextStyle\('),
  RegExp(r'BorderRadius\.circular\(\s*\d'),
];

/// A literal millisecond duration only counts when the line is about motion;
/// timeouts and debounces are not design tokens.
final _durationLiteral = RegExp(r'Duration\(\s*milliseconds:');
final _motionHint = RegExp(r'animat|Animat|transition|curve|duration:');

bool _offends(String line) {
  if (line.trimLeft().startsWith('//')) return false;
  if (_patterns.any((p) => p.hasMatch(line))) return true;
  return _durationLiteral.hasMatch(line) && _motionHint.hasMatch(line);
}

/// `path` → offending `path:line` entries, for every Dart file outside
/// `lib/design/`.
Map<String, List<String>> _offenders() {
  final out = <String, List<String>>{};
  final files = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .where((f) => !f.path.startsWith('lib/design/'));
  for (final f in files) {
    final lines = f.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      if (_offends(lines[i])) {
        out.putIfAbsent(f.path, () => []).add('${f.path}:${i + 1}');
      }
    }
  }
  return out;
}

Set<String> _legacy() => File(_legacyListPath)
    .readAsLinesSync()
    .map((l) => l.trim())
    .where((l) => l.isNotEmpty)
    .toSet();

void main() {
  test('no hardcoded style outside lib/design (except legacy files)', () {
    final legacy = _legacy();
    final fresh = _offenders().entries
        .where((e) => !legacy.contains(e.key))
        .expand((e) => e.value)
        .toList();
    expect(fresh, isEmpty,
        reason: 'Hardcoded colour/text style/radius/animation duration:\n'
            '${fresh.join('\n')}\n'
            'Use context.ds tokens or a Ds component instead.');
  });

  test('legacy list only names files that still need migrating', () {
    final offenders = _offenders().keys.toSet();
    final clean = _legacy().where((p) => !offenders.contains(p)).toList();
    expect(clean, isEmpty,
        reason: clean
            .map((p) => '$p is clean, remove it from $_legacyListPath')
            .join('\n'));
  });
}
