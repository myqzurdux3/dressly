import 'package:flutter/material.dart';

import '../../l10n/app_text.dart';

import '../../app.dart';
import '../../models/model.dart';
import '../../widgets/app_image.dart';
import 'add_model_screen.dart';
import 'model_review_screen.dart';

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
              child: Text(tr(context, 'common.cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr(context, 'common.delete'))),
        ],
      ),
    );
    if (ok == true) {
      try {
        await svc.delete(m.id);
        _reload();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('${tr(context, 'models.deleteFailed')}: $e')));
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'models.title'))),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: TextField(
            controller: _searchCtrl,
            decoration: InputDecoration(
              hintText: tr(context, 'models.searchHint'),
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _searchCtrl.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _searchCtrl.clear();
                        _reload();
                        setState(() {});
                      },
                    ),
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onSubmitted: (_) => _reload(),
            onChanged: (_) => setState(() {}),
            textInputAction: TextInputAction.search,
          ),
        ),
        Expanded(
          child: FutureBuilder<List<ModelEntity>>(
            future: _future,
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              final items = snap.data ?? const [];
              if (items.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.person_outline, size: 64, color: Colors.grey),
                      const SizedBox(height: 12),
                      Text(tr(context, 'models.noMatch'),
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey)),
                    ]),
                  ),
                );
              }
              return GridView.builder(
                padding: const EdgeInsets.all(8),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                  childAspectRatio: 0.8,
                ),
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final m = items[i];
                  return GestureDetector(
                    onTap: () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => ModelReviewScreen(modelId: m.id)),
                      );
                      _reload();
                    },
                    onLongPress: () => _delete(m),
                    child: Stack(children: [
                      Card(
                        clipBehavior: Clip.antiAlias,
                        margin: EdgeInsets.zero,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: Container(
                                color: Colors.blueGrey.shade900,
                                child: m.displayImageUrl == null
                                    ? const Icon(Icons.person, size: 64, color: Colors.white38)
                                    : AppImage.path(
                                        m.displayImageUrl,
                                        cacheKey: m.displayImageUrl,
                                        fit: BoxFit.contain,
                                        memWidth: 300,
                                      ),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.all(10),
                              child: Text(
                                m.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontWeight: FontWeight.bold),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Positioned(
                        top: 4,
                        right: 4,
                        child: DecoratedBox(
                          decoration: const BoxDecoration(
                              color: Colors.black54, shape: BoxShape.circle),
                          child: IconButton(
                            iconSize: 20,
                            padding: const EdgeInsets.all(6),
                            constraints: const BoxConstraints(),
                            visualDensity: VisualDensity.compact,
                            tooltip: tr(context, 'models.deleteTooltip'),
                            icon: const Icon(Icons.delete_outline,
                                color: Colors.redAccent),
                            onPressed: () => _delete(m),
                          ),
                        ),
                      ),
                    ]),
                  );
                },
              );
            },
          ),
        ),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.add),
        label: Text(tr(context, 'models.addTitle')),
      ),
    );
  }
}