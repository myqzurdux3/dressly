import 'package:flutter/material.dart';

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
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'models.reviewTitle'))),
      body: FutureBuilder<ModelEntity>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(child: Text('${tr(context, 'detail.error')}: ${snap.error}'));
          }
          final model = snap.data!;
          if (model.images.isEmpty) {
            return Center(child: Text(tr(context, 'detail.noImages')));
          }
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(model.name,
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(tr(context, 'models.originalNote'),
                    style: TextStyle(color: Colors.white70)),
                const SizedBox(height: 16),
                Text(tr(context, 'models.gender'),
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                SegmentedButton<String>(
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(
                        value: '',
                        label: Text(tr(context, 'models.genderUnspecified'))),
                    ButtonSegment(
                        value: 'male',
                        label: Text(tr(context, 'models.genderMale'))),
                    ButtonSegment(
                        value: 'female',
                        label: Text(tr(context, 'models.genderFemale'))),
                  ],
                  selected: {model.gender},
                  onSelectionChanged: (s) => _setGender(s.first),
                ),
                const SizedBox(height: 16),
                for (final img in model.images)
                  _ModelImageCard(image: img),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _ModelImageCard extends StatelessWidget {
  const _ModelImageCard({required this.image});
  final ModelImage image;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(image.role.toUpperCase(),
                style:
                    const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 8),
          Container(
            constraints: const BoxConstraints(minHeight: 260, maxHeight: 380),
            width: double.infinity,
            color: Colors.blueGrey.shade900,
            child: Center(
              child: InteractiveViewer(
                minScale: 1,
                maxScale: 4,
                // Through the cache, at screen size — Image.network kept no
                // disk copy, so this refetched on every open.
                child: AppImage(
                  url: imageUrl(image.displayUrl),
                  cacheKey: 'mimg-${image.id}-${image.displayUrl}',
                  fit: BoxFit.contain,
                  memWidth: 800,
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}