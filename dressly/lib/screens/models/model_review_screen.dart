import 'package:flutter/material.dart';

import '../../design/ds.dart';
import '../../l10n/app_text.dart';

import '../../app.dart';
import '../../config/api_config.dart';
import '../../models/model.dart';
import '../../widgets/app_image.dart';

/// View-only gallery of a model's pictures. Models keep their background as-is,
/// so there is no accept/reject step — just show what the user uploaded.
class ModelReviewScreen extends StatefulWidget {
  const ModelReviewScreen({super.key, required this.modelId});
  final int modelId;

  @override
  State<ModelReviewScreen> createState() => _ModelReviewScreenState();
}

class _ModelReviewScreenState extends State<ModelReviewScreen> {
  Future<ModelEntity>? _future;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    final future = modelsServiceOf(context).get(widget.modelId);
    setState(() {
      _future = future;
    });
  }

  Future<void> _setGender(String gender) async {
    try {
      await modelsServiceOf(context).update(widget.modelId, gender: gender);
      _reload();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return FutureBuilder<ModelEntity>(
      future: _future,
      builder: (context, snap) {
        final model = snap.data;
        return DsSubPage(
          title: model?.name ?? tr(context, 'models.reviewTitle'),
          onRefresh: () async => _reload(),
          children: [
            if (snap.connectionState == ConnectionState.waiting)
              Padding(
                padding: EdgeInsets.all(ds.space.xl),
                child: Center(
                  child: CircularProgressIndicator(color: ds.colors.accent),
                ),
              )
            else if (snap.hasError)
              DsError(
                message: '${tr(context, 'detail.error')}: ${snap.error}',
                retryLabel: tr(context, 'common.retry'),
                onRetry: _reload,
              )
            else if (model != null) ...[
              Text(
                tr(context, 'models.originalNote'),
                style: ds.typo.label.copyWith(color: ds.colors.textMuted),
              ),
              DsSectionTitle(tr(context, 'models.gender')),
              DsSegment<String>(
                options: [
                  ('', tr(context, 'models.genderUnspecified')),
                  ('male', tr(context, 'models.genderMale')),
                  ('female', tr(context, 'models.genderFemale')),
                ],
                value: model.gender,
                onChanged: _setGender,
              ),
              SizedBox(height: ds.space.m),
              if (model.images.isEmpty)
                Text(tr(context, 'detail.noImages'))
              else
                for (final img in model.images) _ModelImageCard(image: img),
            ],
          ],
        );
      },
    );
  }
}

/// The role comes from the server as "front" / "back" / "extra"; printing it
/// raw put an English "FRONT" on a French screen. Same fix as the cloth detail
/// screen, which had the same badge.
String _roleLabel(BuildContext context, String role) {
  switch (role) {
    case 'front':
      return tr(context, 'form.front');
    case 'back':
      return tr(context, 'form.back');
    default:
      return tr(context, 'form.photo');
  }
}

class _ModelImageCard extends StatelessWidget {
  const _ModelImageCard({required this.image});
  final ModelImage image;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Container(
      margin: EdgeInsets.only(bottom: ds.space.m),
      constraints: const BoxConstraints(minHeight: 260, maxHeight: 420),
      width: double.infinity,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: ds.colors.surface,
        borderRadius: ds.shape.cardRadius,
      ),
      child: Stack(
        children: [
          Center(
            child: InteractiveViewer(
              minScale: 1,
              maxScale: 4,
              // Through the cache, at screen size — Image.network kept no
              // disk copy, so this refetched on every open.
              child: AppImage(
                url: imageUrl(image.displayPreviewUrl),
                cacheKey: 'mimg-${image.id}-${image.displayPreviewUrl}',
                fit: BoxFit.contain,
                memWidth: 800,
              ),
            ),
          ),
          Positioned(
            top: ds.space.s,
            left: ds.space.s,
            child: DsBadge(text: _roleLabel(context, image.role)),
          ),
        ],
      ),
    );
  }
}
