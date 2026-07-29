import 'package:flutter/material.dart';

import '../../app.dart';
import '../../l10n/app_text.dart';
import '../../models/outfit.dart';
import '../../models/stats.dart';
import '../../widgets/app_image.dart';
import '../cloth/cloth_detail_screen.dart';
import '../outfit/outfit_result_dialog.dart';
import '../settings/settings_screen.dart';

/// A quick overview of the user's wardrobe: counts + wear stats, the most-worn
/// outfit, and the clothes worn most often.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  Future<ProfileStats>? _future;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    if (!mounted) return;
    // A block body, not `setState(() => _future = ...)`: an arrow closure
    // RETURNS what it assigns, so that form handed setState a Future and
    // tripped its assertion ("setState() callback argument returned a Future")
    // whenever the screen was opened while a load was still running.
    setState(() {
      _future = statsServiceOf(context).me();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'profile.title')), actions: [
        IconButton(
          icon: const Icon(Icons.settings_outlined),
          tooltip: tr(context, 'profile.settings'),
          onPressed: () => Navigator.push(context,
              MaterialPageRoute(builder: (_) => const SettingsScreen())),
        ),
      ]),
      body: FutureBuilder<ProfileStats>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
                child: Text('${tr(context, 'profile.loadError')}: ${snap.error}'));
          }
          final s = snap.data!;
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                GridView.count(
                  crossAxisCount: 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 1.7,
                  children: [
                    _StatTile(
                        icon: Icons.checkroom,
                        label: tr(context, 'profile.clothes'),
                        value: '${s.clothesCount}'),
                    _StatTile(
                        icon: Icons.auto_awesome,
                        label: tr(context, 'profile.outfitsGenerated'),
                        value: '${s.outfitsGenerated}'),
                    _StatTile(
                        icon: Icons.donut_large,
                        label: tr(context, 'profile.wardrobeWorn'),
                        value: '${s.clothesWornPct}%',
                        sub: '${s.clothesWornCount}/${s.clothesCount} '
                            '${tr(context, 'profile.items')}'),
                    _StatTile(
                        icon: Icons.favorite,
                        label: tr(context, 'profile.savedOutfits'),
                        value: '${s.favoritesCount}'),
                    _StatTile(
                        icon: Icons.event_available,
                        label: tr(context, 'profile.outfitsWorn'),
                        value: '${s.outfitWearsTotal}',
                        sub: tr(context, 'profile.timesTotal')),
                    _StatTile(
                        icon: Icons.history,
                        label: tr(context, 'profile.clothWears'),
                        value: '${s.clothWearsTotal}',
                        sub: tr(context, 'profile.daysLogged')),
                  ],
                ),
                const SizedBox(height: 24),
                _sectionTitle(tr(context, 'profile.mostWornOutfit')),
                const SizedBox(height: 8),
                _mostWornOutfit(s),
                const SizedBox(height: 24),
                _sectionTitle(tr(context, 'profile.mostWornClothes')),
                const SizedBox(height: 8),
                if (s.topClothes.isEmpty)
                  Text(tr(context, 'profile.wearToSee'),
                      style: const TextStyle(color: Colors.grey))
                else
                  ...s.topClothes.map(_topClothTile),
                const SizedBox(height: 24),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _sectionTitle(String t) => Text(t,
      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold));

  Widget _mostWornOutfit(ProfileStats s) {
    final o = s.mostWornOutfit;
    if (o == null) {
      return Text(tr(context, 'profile.noOutfitWorn'),
          style: const TextStyle(color: Colors.grey));
    }
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => showDialog(
          context: context,
          builder: (_) => OutfitResultDialog(outfit: o, onChanged: (_) => _reload()),
        ),
        child: Row(children: [
          SizedBox(
            width: 96,
            height: 120,
            child: AppImage(
                url: outfitImageUrl(o), fit: BoxFit.cover, memWidth: 300),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                      '${tr(context, 'profile.worn')} ${s.mostWornOutfitTimes} '
                      '${trPlural(context, 'profile.time', s.mostWornOutfitTimes)}',
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(
                    [
                      if (o.modelName != null) o.modelName!,
                      if (o.cloths.isNotEmpty)
                        o.cloths.map((c) => c.name).join(', '),
                    ].join(' · '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _topClothTile(TopCloth c) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            width: 44,
            height: 44,
            child: c.thumbUrl.isEmpty
                ? const Icon(Icons.checkroom)
                : AppImage.path(c.thumbUrl, fit: BoxFit.contain, memWidth: 120),
          ),
        ),
        title: Text(c.name,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: c.brand.isEmpty ? null : Text(c.brand),
        trailing: Text('${c.timesWorn}×',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        onTap: () => Navigator.push(context,
            MaterialPageRoute(builder: (_) => ClothDetailScreen(clothId: c.id))),
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.icon,
    required this.label,
    required this.value,
    this.sub,
  });
  final IconData icon;
  final String label;
  final String value;
  final String? sub;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(children: [
              Icon(icon, size: 18, color: scheme.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: Colors.white70)),
              ),
            ]),
            const SizedBox(height: 6),
            Text(value,
                style: const TextStyle(
                    fontSize: 24, fontWeight: FontWeight.bold)),
            if (sub != null)
              Text(sub!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: Colors.white54)),
          ],
        ),
      ),
    );
  }
}
