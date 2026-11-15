import 'package:flutter/material.dart';

import '../ds.dart';

/// Every design-system component on three tabs, with brightness and accent
/// toggles. Started instead of the app with `--dart-define=DS_GALLERY=true`;
/// used to review the components on a real window.
class DsGalleryApp extends StatefulWidget {
  const DsGalleryApp({super.key});

  static const tabLabels = ['Primitives', 'Contenu', 'États'];
  static int get tabCount => tabLabels.length;

  @override
  State<DsGalleryApp> createState() => _DsGalleryAppState();
}

class _DsGalleryAppState extends State<DsGalleryApp> {
  var _brightness = Brightness.dark;
  var _accent = DsAccent.orange;
  var _tab = 0;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: const ThemeF().themeData(_brightness, _accent),
      home: Builder(
        builder: (context) => DsScaffold(
          tabBar: DsTabBar(
            items: const [
              DsTabItem(icon: Icons.widgets, label: 'Primitives'),
              DsTabItem(icon: Icons.checkroom, label: 'Contenu'),
              DsTabItem(icon: Icons.hourglass_empty, label: 'États'),
            ],
            index: _tab,
            onTap: (i) => setState(() => _tab = i),
          ),
          body: ListView(
            key: PageStorageKey(_tab),
            padding: EdgeInsets.only(bottom: DsScaffold.bottomInset(context)),
            children: [
              DsHeader(
                line1: 'Galerie',
                line2: DsGalleryApp.tabLabels[_tab],
                meta: [_brightness.name, _accent.name],
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DsButton.icon(
                      key: const ValueKey('gallery-accent'),
                      icon: Icons.palette,
                      semanticLabel: 'Accent suivant',
                      onPressed: () => setState(() {
                        _accent =
                            DsAccent.values[(_accent.index + 1) %
                                DsAccent.values.length];
                      }),
                    ),
                    SizedBox(width: context.ds.space.s),
                    DsButton.icon(
                      key: const ValueKey('gallery-brightness'),
                      icon: Icons.contrast,
                      semanticLabel: 'Clair / sombre',
                      onPressed: () => setState(() {
                        _brightness = _brightness == Brightness.dark
                            ? Brightness.light
                            : Brightness.dark;
                      }),
                    ),
                  ],
                ),
              ),
              ...switch (_tab) {
                0 => _primitives(context),
                1 => _content(context),
                _ => _states(context),
              },
            ],
          ),
        ),
      ),
    );
  }
}

/// Section title + padded body.
class _Section extends StatelessWidget {
  const _Section(this.title, this.child);

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        ds.space.gutter,
        ds.space.l,
        ds.space.gutter,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title.toUpperCase(), style: ds.typo.mono),
          SizedBox(height: ds.space.s),
          child,
        ],
      ),
    );
  }
}

Widget _thumb(BuildContext context, String color) {
  final t = garmentTone(color, Theme.of(context).brightness);
  return Icon(Icons.checkroom, size: 80, color: t.shade);
}

List<Widget> _primitives(BuildContext context) {
  final gap = SizedBox(height: context.ds.space.s);
  return [
    _Section(
      'Boutons',
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DsButton(label: 'Je mets ça', onPressed: () {}, expand: true),
          gap,
          Wrap(
            spacing: context.ds.space.s,
            runSpacing: context.ds.space.s,
            children: [
              DsButton(
                label: 'Autre',
                icon: Icons.refresh,
                kind: DsButtonKind.secondary,
                onPressed: () {},
              ),
              DsButton.icon(
                icon: Icons.refresh,
                semanticLabel: 'Autre',
                onPressed: () {},
              ),
              const DsButton(label: 'Désactivé', onPressed: null),
            ],
          ),
          gap,
          DsButton(label: 'Chargement', loading: true, onPressed: () {}),
        ],
      ),
    ),
    _Section('Filtres', _SegmentDemo()),
    const _Section(
      'Badges',
      Row(
        children: [
          DsBadge(text: 'top'),
          SizedBox(width: 8),
          DsBadge(text: 'dort', tone: DsBadgeTone.accent),
        ],
      ),
    ),
    const _Section(
      'En-tête',
      DsHeader(
        line1: 'Tenue du',
        line2: 'jour',
        meta: ['sam 15.11', '9° · pluie'],
      ),
    ),
  ];
}

class _SegmentDemo extends StatefulWidget {
  @override
  State<_SegmentDemo> createState() => _SegmentDemoState();
}

class _SegmentDemoState extends State<_SegmentDemo> {
  var _v = 0;

  @override
  Widget build(BuildContext context) => DsSegment<int>(
    options: const [
      (0, 'Tout'),
      (1, 'Hoodies'),
      (2, 'Bas'),
      (3, 'Sneakers'),
      (4, 'Vestes'),
    ],
    value: _v,
    onChanged: (v) => setState(() => _v = v),
  );
}

List<Widget> _content(BuildContext context) {
  final b = Theme.of(context).brightness;
  DsSwatchCard card(String c, String name, String sub, {String? badge}) =>
      DsSwatchCard(
        image: _thumb(context, c),
        name: name,
        subtitle: sub,
        tone: garmentTone(c, b),
        badge: badge,
        trailing: IconButton(
          onPressed: () {},
          icon: const Icon(Icons.favorite_border),
        ),
        onTap: () {},
      );
  final days = [
    for (var i = 0; i < 5; i++)
      DsDay(
        date: DateTime(2026, 11, 13 + i),
        weekday: const ['jeu', 'ven', 'sam', 'dim', 'lun'][i],
        hasPlan: i != 3,
      ),
  ];
  return [
    _Section(
      'Vêtements',
      GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        crossAxisSpacing: context.ds.space.s,
        mainAxisSpacing: context.ds.space.s,
        childAspectRatio: DsSwatchCard.aspectRatio,
        children: [
          card('Orange', 'Hoodie orange', '14× porté', badge: 'top'),
          card('Green', 'Cargo kaki', '21× porté'),
          card('Beige', 'Runners crème', '30× porté'),
          card('Black', 'Doudoune noire', '6× porté', badge: 'dort'),
        ],
      ),
    ),
    _Section('Semaine', _DayStripDemo(days: days)),
    _Section(
      'Plans',
      Column(
        children: [
          DsPlanCard(
            title: 'Bureau',
            subtitle: "aujourd'hui · 9°",
            tone: garmentTone('Orange', b),
            thumbs: [_thumb(context, 'Black'), _thumb(context, 'Orange')],
            onTap: () {},
          ),
          SizedBox(height: context.ds.space.s),
          DsPlanCard(
            title: 'Dimanche',
            subtitle: 'rien de prévu · 8°',
            thumbs: const [],
            onTap: () {},
          ),
        ],
      ),
    ),
    _Section(
      'Couches',
      Column(
        children: [
          DsLayerRow(
            index: 'L3·ext',
            image: _thumb(context, 'Black'),
            name: 'Doudoune noire',
            note: 'imperméable',
          ),
          DsLayerRow(
            index: 'L2·mid',
            image: _thumb(context, 'Grey'),
            name: 'Hoodie gris',
            note: 'chaleur',
          ),
          DsLayerRow(
            index: 'bas',
            image: _thumb(context, 'Green'),
            name: 'Cargo kaki',
            note: 'ripstop',
          ),
        ],
      ),
    ),
    _Section('Collage', _CollageDemo()),
  ];
}

class _DayStripDemo extends StatefulWidget {
  const _DayStripDemo({required this.days});

  final List<DsDay> days;

  @override
  State<_DayStripDemo> createState() => _DayStripDemoState();
}

class _DayStripDemoState extends State<_DayStripDemo> {
  late var _sel = widget.days[2].date;

  @override
  Widget build(BuildContext context) => DsDayStrip(
    days: widget.days,
    selected: _sel,
    onSelect: (d) => setState(() => _sel = d),
  );
}

class _CollageDemo extends StatefulWidget {
  @override
  State<_CollageDemo> createState() => _CollageDemoState();
}

class _CollageDemoState extends State<_CollageDemo> {
  var _run = 0;

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DsCollage(
          key: ValueKey(_run),
          pieces: [
            for (final c in ['Black', 'Orange', 'Green', 'White'])
              ColoredBox(
                color: garmentTone(c, b).fill,
                child: _thumb(context, c),
              ),
          ],
        ),
        SizedBox(height: context.ds.space.s),
        DsButton(
          label: 'Rejouer',
          icon: Icons.replay,
          kind: DsButtonKind.secondary,
          onPressed: () => setState(() => _run++),
        ),
      ],
    );
  }
}

List<Widget> _states(BuildContext context) => [
  _Section(
    'Vide',
    DsEmpty(
      title: 'Rien de prévu',
      message: 'Planifie une tenue pour un jour de la semaine.',
      actionLabel: 'Planifier',
      onAction: () {},
    ),
  ),
  _Section(
    'Erreur',
    DsError(
      message: 'Serveur injoignable.',
      retryLabel: 'Réessayer',
      onRetry: () {},
    ),
  ),
  _Section(
    'Feuille',
    Builder(
      builder: (c) => DsButton(
        label: 'Ouvrir',
        kind: DsButtonKind.secondary,
        onPressed: () => showDsSheet<void>(
          c,
          title: 'Trier par',
          child: const DsSegment<int>(
            options: [(0, 'Récent'), (1, 'Porté'), (2, 'Note')],
            value: 0,
            onChanged: _noop,
          ),
        ),
      ),
    ),
  ),
  const _Section('Chargement', DsSkeleton.swatchGrid()),
];

void _noop(int _) {}
