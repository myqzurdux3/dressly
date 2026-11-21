import 'package:flutter/material.dart';

import '../app.dart';
import '../design/ds.dart';
import '../l10n/app_text.dart';
import '../models/model.dart';

/// Who wears an AI render: nobody, someone at random, or one of the models.
/// Returns 'none', 'random' or a model id as text; null when dismissed.
Future<String?> pickRenderPerson(BuildContext context) async {
  List<ModelEntity> models = const [];
  try {
    models = await modelsServiceOf(context).list();
  } catch (_) {
    // Without the list the clothes-only and random choices still work.
  }
  if (!context.mounted) return null;
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _PersonSheet(models: models),
  );
}

class _PersonSheet extends StatelessWidget {
  const _PersonSheet({required this.models});
  final List<ModelEntity> models;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: EdgeInsets.fromLTRB(
          ds.space.gutter,
          0,
          ds.space.gutter,
          ds.space.l,
        ),
        children: [
          Text(
            tr(context, 'stylist.renderOn').toUpperCase(),
            style: ds.typo.headline,
          ),
          SizedBox(height: ds.space.xs),
          Text(
            tr(context, 'stylist.renderCost'),
            style: ds.typo.label.copyWith(color: ds.colors.textMuted),
          ),
          SizedBox(height: ds.space.s),
          DsInfoRow(
            icon: Icons.checkroom,
            title: tr(context, 'stylist.renderNoPerson'),
            onTap: () => Navigator.pop(context, 'none'),
          ),
          if (models.isNotEmpty)
            DsInfoRow(
              icon: Icons.shuffle,
              title: tr(context, 'stylist.renderRandom'),
              onTap: () => Navigator.pop(context, 'random'),
            ),
          for (final m in models)
            DsInfoRow(
              icon: Icons.person_outline,
              title: m.name,
              onTap: () => Navigator.pop(context, '${m.id}'),
            ),
        ],
      ),
    );
  }
}
