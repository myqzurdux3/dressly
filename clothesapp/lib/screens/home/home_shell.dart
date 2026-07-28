import 'package:flutter/material.dart';

import '../../l10n/app_text.dart';

import '../agenda/agenda_screen.dart';
import '../outfit/favorites_screen.dart';
import '../outfit/outfit_screen.dart';
import '../profile/profile_screen.dart';
import 'collection_screen.dart';

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

  static const _pages = [
    CollectionScreen(),
    OutfitScreen(),
    AgendaScreen(),
    FavoritesScreen(),
    ProfileScreen(),
  ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _go(int i) {
    setState(() => _index = i);
    _controller.animateToPage(
      i,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: PageView(
        controller: _controller,
        onPageChanged: (i) => setState(() => _index = i),
        children: _pages,
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
