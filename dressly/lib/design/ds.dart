/// The Dressly design system. Screens import this file only.
library;

import 'package:flutter/material.dart';

import 'tokens.dart';

export 'accent.dart';
export 'components/ds_badge.dart';
export 'components/ds_button.dart';
export 'components/ds_chip.dart';
export 'components/ds_collage.dart';
export 'components/ds_sheet.dart';
export 'components/ds_states.dart';
export 'components/ds_day_strip.dart';
export 'components/ds_layer_row.dart';
export 'components/ds_plan_card.dart';
export 'components/ds_pressable.dart';
export 'components/ds_swatch_card.dart';
export 'components/ds_header.dart';
export 'components/ds_rating.dart';
export 'components/ds_scaffold.dart';
export 'components/ds_search_field.dart';
export 'components/ds_tab_bar.dart';
export 'garment_tones.dart';
export 'ds_theme.dart';
export 'theme_f.dart';
export 'tokens.dart';

extension DsContext on BuildContext {
  /// Tokens of the active theme.
  DsTokens get ds {
    final tokens = Theme.of(this).extension<DsTokens>();
    if (tokens == null) throw StateError('DsTokens missing from Theme');
    return tokens;
  }
}
