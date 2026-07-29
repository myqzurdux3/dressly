import 'package:flutter/material.dart';

import '../../l10n/app_text.dart';

import '../agenda/agenda_screen.dart';
import '../outfit/favorites_screen.dart';
import '../outfit/outfit_screen.dart';
import '../profile/profile_screen.dart';
import 'collection_screen.dart';
import 'lazy_page.dart';

/// Top-level shell: four swipeable pages with a bottom navigation bar
/// (Instagram-style). Swiping left/right moves between Wardrobe, Create,
/// Agenda and Saved; tapping a destination animates to it. Replacing the pile
/// of app-bar icons declutters the top of every screen.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  final _controller = PageController();
  int _index = 0;

  // Builders, not instances: a PageView given a `children:` list builds every
  // page at once, so opening the app fired all five screens' requests together
  // and queued all their images behind one another.
  static final _pages = <WidgetBuilder>[
    (_) => const CollectionScreen(),
    (_) => const OutfitScreen(),
    (_) => const AgendaScreen(),
    (_) => const FavoritesScreen(),
    (_) => const ProfileScreen(),
  ];

  /// Pages that have been shown at least once, and so stay built.
  final Set<int> _visited = {0};

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _go(int i) {
    setState(() {
      _index = i;
      _visited.add(i);
    });
    // jumpToPage, not animateToPage: animating scrolls THROUGH every page in
    // between and builds each one as it passes, so tapping Agenda from the
    // wardrobe also started the outfit builder — including its unpaginated
    // /clothes fetch — and queued its images. Swiping still builds neighbours,
    // which is what swiping means; tapping should not.
    _controller.jumpToPage(i);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // A page is marked visited as soon as it starts coming into view, not
      // when the swipe settles: otherwise the page being swiped towards stays
      // blank for the length of the gesture.
      body: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n is ScrollUpdateNotification && _controller.hasClients) {
            final page = _controller.page;
            if (page != null) {
              final approaching = {page.floor(), page.ceil()}
                  .where((i) => i >= 0 && i < _pages.length)
                  .where((i) => !_visited.contains(i))
                  .toSet();
              if (approaching.isNotEmpty) {
                setState(() => _visited.addAll(approaching));
              }
            }
          }
          return false;
        },
        child: PageView(
        controller: _controller,
        onPageChanged: (i) => setState(() {
          _index = i;
          _visited.add(i);
        }),
        children: [
          for (var i = 0; i < _pages.length; i++)
            LazyPage(isActive: _visited.contains(i), builder: _pages[i]),
        ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: _go,
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.checkroom_outlined),
            selectedIcon: const Icon(Icons.checkroom),
            label: tr(context, 'nav.wardrobe'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.auto_awesome_outlined),
            selectedIcon: const Icon(Icons.auto_awesome),
            label: tr(context, 'nav.create'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.calendar_month_outlined),
            selectedIcon: const Icon(Icons.calendar_month),
            label: tr(context, 'nav.agenda'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.favorite_border),
            selectedIcon: const Icon(Icons.favorite),
            label: tr(context, 'nav.saved'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.person_outline),
            selectedIcon: const Icon(Icons.person),
            label: tr(context, 'nav.profile'),
          ),
        ],
      ),
    );
  }
}
