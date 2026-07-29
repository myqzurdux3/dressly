import 'package:clothesapp/screens/home/lazy_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A PageView given a `children:` list builds every page at once. With five
/// tabs that meant opening the app fired all five screens' requests together —
/// the server log showed /agenda, /models, /outfits/favorites/list, /clothes
/// twice and both autocomplete endpoints inside one second — and queued every
/// screen's images behind one another through a ten-slot download queue.

/// Records how many times it was built, standing in for a screen that loads.
class _Counting extends StatefulWidget {
  const _Counting(this.built);
  final List<String> built;

  @override
  State<_Counting> createState() => _CountingState();
}

class _CountingState extends State<_Counting> {
  @override
  void initState() {
    super.initState();
    widget.built.add('built');   // where a real screen fires its requests
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}

Widget _host({required bool active, required List<String> built}) =>
    MaterialApp(
      home: LazyPage(isActive: active, builder: (_) => _Counting(built)),
    );

void main() {
  testWidgets('an inactive page does not build its child', (tester) async {
    final built = <String>[];
    await tester.pumpWidget(_host(active: false, built: built));

    expect(built, isEmpty,
        reason: 'a tab that was never opened must not issue its requests');
  });

  testWidgets('an active page builds immediately', (tester) async {
    final built = <String>[];
    await tester.pumpWidget(_host(active: true, built: built));

    expect(built, hasLength(1));
  });

  testWidgets('becoming active builds it once', (tester) async {
    final built = <String>[];
    await tester.pumpWidget(_host(active: false, built: built));
    expect(built, isEmpty);

    await tester.pumpWidget(_host(active: true, built: built));
    expect(built, hasLength(1));
  });

  testWidgets('going away and back does not rebuild or refetch',
      (tester) async {
    // Deferring is wanted; discarding is not. Returning to a tab should be
    // instant rather than reloading it.
    final built = <String>[];
    await tester.pumpWidget(_host(active: true, built: built));
    await tester.pumpWidget(_host(active: false, built: built));
    await tester.pumpWidget(_host(active: true, built: built));

    expect(built, hasLength(1),
        reason: 'the page was rebuilt, so its screen reloaded');
  });

  testWidgets('a visited tab survives being scrolled out of view',
      (tester) async {
    // The measured regression: PageView destroys an off-screen page and runs
    // its initState again on return. The server saw five /clothes and four
    // /models in three seconds from a single screen, each /clothes returning
    // the whole unpaginated wardrobe.
    final built = List.generate(3, (_) => <String>[]);
    final controller = PageController();
    addTearDown(controller.dispose);
    final visited = <int>{0};

    Widget shell() => MaterialApp(
          home: PageView(
            controller: controller,
            children: [
              for (var i = 0; i < 3; i++)
                LazyPage(
                  isActive: visited.contains(i),
                  builder: (_) => _Counting(built[i]),
                ),
            ],
          ),
        );

    await tester.pumpWidget(shell());
    expect(built[0], hasLength(1));

    // Go to the far tab, then back.
    visited.add(2);
    controller.jumpToPage(2);
    await tester.pumpWidget(shell());
    await tester.pumpAndSettle();
    expect(built[2], hasLength(1));

    controller.jumpToPage(0);
    await tester.pumpWidget(shell());
    await tester.pumpAndSettle();

    expect(built[0], hasLength(1),
        reason: 'returning to a tab rebuilt it, so it refetched everything');

    // And once more, in case the first return was luck.
    controller.jumpToPage(2);
    await tester.pumpWidget(shell());
    await tester.pumpAndSettle();
    controller.jumpToPage(0);
    await tester.pumpWidget(shell());
    await tester.pumpAndSettle();

    expect(built[0], hasLength(1));
    expect(built[2], hasLength(1));
  });

  testWidgets('tapping a far tab does not build the ones in between',
      (tester) async {
    // The regression: animateToPage scrolls through every intermediate page and
    // builds it. Jumping goes straight there.
    final built = List.generate(5, (_) => <String>[]);
    final controller = PageController();
    addTearDown(controller.dispose);
    final visited = <int>{0};

    Widget shell() => MaterialApp(
          home: PageView(
            controller: controller,
            children: [
              for (var i = 0; i < 5; i++)
                LazyPage(
                  isActive: visited.contains(i),
                  builder: (_) => _Counting(built[i]),
                ),
            ],
          ),
        );

    await tester.pumpWidget(shell());
    expect(built[0], hasLength(1), reason: 'the first tab should load');

    // Tap "Agenda" (index 2) from the wardrobe.
    visited.add(2);
    controller.jumpToPage(2);
    await tester.pumpWidget(shell());
    await tester.pumpAndSettle();

    expect(built[2], hasLength(1), reason: 'the tapped tab must load');
    expect(built[1], isEmpty,
        reason: 'the tab passed over must NOT load — that is what '
            'animateToPage did');
    expect(built[3], isEmpty);
    expect(built[4], isEmpty);
  });
}
