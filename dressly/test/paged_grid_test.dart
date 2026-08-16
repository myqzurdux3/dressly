import 'dart:async';

import 'package:dressly/state/paged_list.dart';
import 'package:dressly/widgets/paged_grid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// NOTE: `pumpAndSettle` cannot be used while the grid still `hasMore` — the
/// trailing CircularProgressIndicator animates forever and settling never
/// completes. These tests pump explicit frames instead.

PagedList<int> _controller({required int total, int pageSize = 12}) {
  return PagedList<int>(
    pageSize: pageSize,
    fetchPage: ({required limit, required offset}) async {
      if (offset >= total) return [];
      return List.generate((total - offset).clamp(0, limit), (i) => offset + i);
    },
  );
}

Widget _harness(PagedList<int> controller, {Future<void> Function()? onRefresh}) {
  return MaterialApp(
    home: Scaffold(
      body: PagedGrid<int>(
        controller: controller,
        onRefresh: onRefresh,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          childAspectRatio: 1,
        ),
        emptyBuilder: (_) => const Text('nothing here'),
        header: (count) => Text('$count items'),
        itemBuilder: (_, item) => SizedBox(height: 100, child: Text('#$item')),
      ),
    ),
  );
}

void main() {
  testWidgets('shows a spinner on the very first load', (tester) async {
    final completer = Completer<List<int>>();
    final c = PagedList<int>(
      fetchPage: ({required limit, required offset}) => completer.future,
    );
    await tester.pumpWidget(_harness(c));
    unawaited(c.refresh());
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    completer.complete(<int>[]);
    await tester.pump();
    await tester.pump();
  });

  testWidgets('renders the first page and the header count', (tester) async {
    final c = _controller(total: 50);
    await tester.pumpWidget(_harness(c));
    await c.refresh();
    await tester.pump();

    expect(find.text('12 items'), findsOneWidget);
    expect(find.text('#0'), findsOneWidget);
  });

  testWidgets('shows the empty state when there is nothing', (tester) async {
    final c = _controller(total: 0);
    await tester.pumpWidget(_harness(c));
    await c.refresh();
    await tester.pumpAndSettle();

    expect(find.text('nothing here'), findsOneWidget);
  });

  testWidgets('scrolling to the bottom loads the next page', (tester) async {
    final c = _controller(total: 60);
    await tester.pumpWidget(_harness(c));
    await c.refresh();
    await tester.pump();
    expect(c.items.length, 12);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -2000));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(c.items.length, greaterThan(12),
        reason: 'reaching the bottom must trigger loadMore');
  });

  testWidgets('no trailing spinner once the last page is in', (tester) async {
    final c = _controller(total: 5);
    await tester.pumpWidget(_harness(c));
    await c.refresh();
    await tester.pumpAndSettle();

    expect(c.hasMore, isFalse);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('a local mutation repaints without a refetch', (tester) async {
    var fetches = 0;
    final c = PagedList<int>(
      pageSize: 10,
      fetchPage: ({required limit, required offset}) async {
        fetches++;
        return offset == 0 ? [1, 2, 3] : <int>[];
      },
    );
    await tester.pumpWidget(_harness(c));
    await c.refresh();
    await tester.pumpAndSettle();
    expect(fetches, 1);

    c.replaceItem((v) => v == 2, 99);
    await tester.pumpAndSettle();

    expect(find.text('#99'), findsOneWidget);
    expect(find.text('#2'), findsNothing);
    expect(fetches, 1, reason: 'the whole point: no round trip for a toggle');
  });

  testWidgets('pull-to-refresh is available over the empty state too',
      (tester) async {
    var refreshed = 0;
    final c = _controller(total: 0);
    await tester.pumpWidget(_harness(c, onRefresh: () async {
      refreshed++;
      await c.refresh();
    }));
    await c.refresh();
    await tester.pumpAndSettle();

    await tester.fling(find.text('nothing here'), const Offset(0, 400), 1000);
    await tester.pumpAndSettle();

    expect(refreshed, greaterThan(0));
  });
}
