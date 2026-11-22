import 'package:flutter/material.dart';

import '../../app.dart';
import '../../design/ds.dart';
import '../../l10n/app_text.dart';
import '../../models/outfit.dart';
import '../../models/stats.dart';
import '../../widgets/app_image.dart';
import '../cloth/cloth_detail_screen.dart';
import '../cloth/dormant_screen.dart';
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
    final ds = context.ds;
    final c = ds.colors;
    final muted = ds.typo.label.copyWith(color: c.textMuted);
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: FutureBuilder<ProfileStats>(
          future: _future,
          builder: (context, snap) {
            final header = DsHeader(
              line1: '',
              line2: tr(context, 'profile.title'),
              trailing: DsButton.icon(
                icon: Icons.settings_outlined,
                semanticLabel: tr(context, 'profile.settings'),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                ),
              ),
            );
            Widget body;
            if (snap.connectionState == ConnectionState.waiting &&
                !snap.hasData) {
              body = Padding(
                padding: EdgeInsets.all(ds.space.xl),
                child: Center(
                  child: CircularProgressIndicator(color: c.accent),
                ),
              );
            } else if (snap.hasError) {
              body = DsError(
                message: '${tr(context, 'profile.loadError')}: ${snap.error}',
                retryLabel: tr(context, 'common.retry'),
                onRetry: _reload,
              );
            } else {
              final s = snap.data!;
              body = Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  GridView.count(
                    crossAxisCount: 2,
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    physics: const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: ds.space.s,
                    crossAxisSpacing: ds.space.s,
                    childAspectRatio: 1.5,
                    children: [
                      _StatTile(
                        label: tr(context, 'profile.clothes'),
                        value: '${s.clothesCount}',
                        accent: true,
                      ),
                      _StatTile(
                        label: tr(context, 'profile.outfitsGenerated'),
                        value: '${s.outfitsGenerated}',
                      ),
                      _StatTile(
                        label: tr(context, 'profile.wardrobeWorn'),
                        value: '${s.clothesWornPct}%',
                        sub:
                            '${s.clothesWornCount}/${s.clothesCount} '
                            '${tr(context, 'profile.items')}',
                      ),
                      _StatTile(
                        label: tr(context, 'profile.savedOutfits'),
                        value: '${s.favoritesCount}',
                      ),
                      _StatTile(
                        label: tr(context, 'profile.outfitsWorn'),
                        value: '${s.outfitWearsTotal}',
                        sub: tr(context, 'profile.timesTotal'),
                      ),
                      _StatTile(
                        label: tr(context, 'profile.clothWears'),
                        value: '${s.clothWearsTotal}',
                        sub: tr(context, 'profile.daysLogged'),
                      ),
                    ],
                  ),
                  SizedBox(height: ds.space.s),
                  // Sits right under "wardrobe worn": the percentage says how
                  // much of the wardrobe is in use, this is the way into the
                  // rest.
                  DsPressable(
                    onTap: () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const DormantScreen(),
                        ),
                      );
                      // Wearing or removing something in there changes the
                      // counts above.
                      _reload();
                    },
                    child: Container(
                      padding: EdgeInsets.all(ds.space.m),
                      decoration: BoxDecoration(
                        color: c.surface,
                        borderRadius: ds.shape.cardRadius,
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.hourglass_empty, color: c.accentText),
                          SizedBox(width: ds.space.s),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  tr(context, 'profile.dormant'),
                                  style: ds.typo.bodyStrong,
                                ),
                                Text(
                                  tr(context, 'profile.dormantHint'),
                                  style: muted,
                                ),
                              ],
                            ),
                          ),
                          Icon(Icons.chevron_right, color: c.textMuted),
                        ],
                      ),
                    ),
                  ),
                  DsSectionTitle(tr(context, 'profile.mostWornOutfit')),
                  _mostWornOutfit(s),
                  DsSectionTitle(tr(context, 'profile.mostWornClothes')),
                  if (s.topClothes.isEmpty)
                    Text(tr(context, 'profile.wearToSee'), style: muted)
                  else
                    for (final (i, cloth) in s.topClothes.indexed)
                      _topClothRow(i, cloth),
                ],
              );
            }
            return RefreshIndicator(
              color: c.accent,
              onRefresh: () async => _reload(),
              child: ListView(
                padding: EdgeInsets.only(bottom: ds.space.xl * 3),
                children: [
                  header,
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: ds.space.gutter),
                    child: body,
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _mostWornOutfit(ProfileStats s) {
    final ds = context.ds;
    final c = ds.colors;
    final o = s.mostWornOutfit;
    if (o == null) {
      return Text(
        tr(context, 'profile.noOutfitWorn'),
        style: ds.typo.label.copyWith(color: c.textMuted),
      );
    }
    return DsPressable(
      onTap: () => showDialog(
        context: context,
        builder: (_) =>
            OutfitResultDialog(outfit: o, onChanged: (_) => _reload()),
      ),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: ds.shape.cardRadius,
        ),
        child: Row(
          children: [
            SizedBox(
              width: 96,
              height: 120,
              child: AppImage(
                url: outfitImageUrl(o),
                fit: BoxFit.cover,
                memWidth: 300,
              ),
            ),
            Expanded(
              child: Padding(
                padding: EdgeInsets.all(ds.space.m),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${tr(context, 'profile.worn')} ${s.mostWornOutfitTimes} '
                              '${trPlural(context, 'profile.time', s.mostWornOutfitTimes)}'
                          .toUpperCase(),
                      style: ds.typo.headline,
                    ),
                    SizedBox(height: ds.space.xs / 2),
                    Text(
                      [
                        ?o.modelName,
                        if (o.cloths.isNotEmpty)
                          o.cloths.map((c) => c.name).join(', '),
                      ].join(' · '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: ds.typo.label.copyWith(color: c.textMuted),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Ranked like a list of layers: index, picture, name, wear count.
  Widget _topClothRow(int i, TopCloth cloth) {
    final ds = context.ds;
    return Padding(
      padding: EdgeInsets.only(bottom: ds.space.xs),
      child: DsPressable(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ClothDetailScreen(clothId: cloth.id),
          ),
        ),
        child: DsLayerRow(
          index: '${i + 1}'.padLeft(2, '0'),
          image: cloth.thumbUrl.isEmpty
              ? Icon(Icons.checkroom, color: ds.colors.textMuted)
              : AppImage.path(
                  cloth.thumbUrl,
                  fit: BoxFit.contain,
                  memWidth: 120,
                ),
          name: cloth.name,
          note: [
            if (cloth.brand.isNotEmpty) cloth.brand,
            '${cloth.timesWorn}×',
          ].join(' · '),
        ),
      ),
    );
  }
}

/// One number on a card: mono label, big value, optional mono detail.
class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.label,
    required this.value,
    this.sub,
    this.accent = false,
  });

  final String label;
  final String value;
  final String? sub;

  /// The headline number: on the accent fill.
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final c = ds.colors;
    final ink = accent ? c.onAccent : c.text;
    return Container(
      padding: EdgeInsets.all(ds.space.m),
      decoration: BoxDecoration(
        color: accent ? c.accent : c.surface,
        borderRadius: ds.shape.cardRadius,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label.toUpperCase(),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: ds.typo.monoSmall.copyWith(
              color: ink.withValues(alpha: 0.75),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value,
                style: ds.typo.display.copyWith(color: ink, fontSize: 40),
              ),
              if (sub != null)
                Text(
                  sub!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ds.typo.monoSmall.copyWith(
                    color: ink.withValues(alpha: 0.7),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
