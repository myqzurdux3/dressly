import 'package:flutter/material.dart';

import '../../l10n/app_text.dart';

import '../../app.dart';
import '../../design/ds.dart';
import '../../models/model.dart';
import '../../widgets/app_image.dart';
import 'add_model_screen.dart';
import 'model_review_screen.dart';
import '../../widgets/error_toast.dart';

class ModelsScreen extends StatefulWidget {
  const ModelsScreen({super.key});

  @override
  State<ModelsScreen> createState() => _ModelsScreenState();
}

class _ModelsScreenState extends State<ModelsScreen> {
  Future<List<ModelEntity>>? _future;
  final _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _reload() {
    setState(() {
      _future = modelsServiceOf(context).list(search: _searchCtrl.text.trim());
    });
  }

  Future<void> _add() async {
    final ok = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const AddModelScreen()),
    );
    if (ok == true) _reload();
  }

  Future<void> _delete(ModelEntity m) async {
    final svc = modelsServiceOf(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(tr(context, 'models.deleteTitle')),
        content: Text(tr(context, 'models.deleteConfirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr(context, 'common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr(context, 'common.delete')),
          ),
        ],
      ),
    );
    if (ok == true) {
      try {
        await svc.delete(m.id);
        _reload();
      } catch (e) {
        toastError(e, prefixKey: 'models.deleteFailed');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final c = ds.colors;
    return DsSubPage(
      title: tr(context, 'models.title'),
      onRefresh: () async => _reload(),
      actions: [
        DsButton.icon(
          icon: Icons.add,
          semanticLabel: tr(context, 'models.addTitle'),
          onPressed: _add,
        ),
      ],
      children: [
        DsSearchField(
          controller: _searchCtrl,
          hint: tr(context, 'models.searchHint'),
          clearLabel: tr(context, 'common.clear'),
          onChanged: (v) {
            // Cleared with the cross: list everything again.
            if (v.isEmpty) _reload();
            setState(() {});
          },
          onSubmitted: (_) => _reload(),
        ),
        SizedBox(height: ds.space.m),
        FutureBuilder<List<ModelEntity>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return Padding(
                padding: EdgeInsets.all(ds.space.xl),
                child: Center(
                  child: CircularProgressIndicator(color: c.accent),
                ),
              );
            }
            // A failed request is not an empty list of models: say so,
            // instead of showing the "nothing matches" state.
            if (snap.hasError) {
              return DsError(
                message: '${tr(context, 'detail.error')}: ${snap.error}',
                retryLabel: tr(context, 'common.retry'),
                onRetry: _reload,
              );
            }
            final items = snap.data ?? const [];
            if (items.isEmpty) {
              return DsEmpty(
                title: tr(context, 'models.noMatch'),
                message: '',
                actionLabel: tr(context, 'models.addTitle'),
                onAction: _add,
              );
            }
            return GridView.builder(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: ds.space.s,
                mainAxisSpacing: ds.space.s,
                childAspectRatio: 0.75,
              ),
              itemCount: items.length,
              itemBuilder: (context, i) => _ModelCard(
                model: items[i],
                onTap: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ModelReviewScreen(modelId: items[i].id),
                    ),
                  );
                  _reload();
                },
                onDelete: () => _delete(items[i]),
              ),
            );
          },
        ),
      ],
    );
  }
}

class _ModelCard extends StatelessWidget {
  const _ModelCard({
    required this.model,
    required this.onTap,
    required this.onDelete,
  });

  final ModelEntity model;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final c = ds.colors;
    return DsPressable(
      onTap: onTap,
      onLongPress: onDelete,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: ds.shape.cardRadius,
        ),
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: model.thumbImageUrl == null
                      ? Icon(Icons.person, size: 64, color: c.textMuted)
                      : AppImage.path(
                          model.thumbImageUrl,
                          cacheKey: model.thumbImageUrl,
                          fit: BoxFit.cover,
                          memWidth: 300,
                        ),
                ),
                Padding(
                  padding: EdgeInsets.all(ds.space.s),
                  child: Text(
                    model.name.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ds.typo.headline,
                  ),
                ),
              ],
            ),
            Positioned(
              top: ds.space.xs,
              right: ds.space.xs,
              child: DsButton.icon(
                icon: Icons.delete_outline,
                semanticLabel: tr(context, 'models.deleteTooltip'),
                onPressed: onDelete,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
