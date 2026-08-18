import 'dart:async';

import 'package:dressly/state/paged_list.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records what the controller asked for, so tests can assert on the cursor
/// arithmetic rather than just on the resulting list.
class _FakeSource {
  _FakeSource(this.total, {this.delay = Duration.zero});

  final int total;
  final Duration delay;
  final List<({int limit, int offset})> calls = [];

  Future<List<int>> fetch({required int limit, required int offset}) async {
    calls.add((limit: limit, offset: offset));
    if (delay != Duration.zero) await Future<void>.delayed(delay);
    if (offset >= total) return [];
    return List.generate(
        (total - offset).clamp(0, limit), (i) => offset + i);
  }
}

void main() {
  group('PagedList paging', () {
    test('refresh loads the first page only', () async {
      final src = _FakeSource(100);
      final list = PagedList<int>(fetchPage: src.fetch, pageSize: 10);

      await list.refresh();

      expect(list.items, List.generate(10, (i) => i));
      expect(src.calls.single, (limit: 10, offset: 0));
      expect(list.hasMore, isTrue);
    });

    test('loadMore appends the next page using the loaded count as offset',
        () async {
      final src = _FakeSource(100);
      final list = PagedList<int>(fetchPage: src.fetch, pageSize: 10);

      await list.refresh();
      await list.loadMore();

      expect(list.items.length, 20);
      expect(list.items.last, 19);
      expect(src.calls[1], (limit: 10, offset: 10));
    });

    test('a short page marks the end of the list', () async {
      final src = _FakeSource(15);
      final list = PagedList<int>(fetchPage: src.fetch, pageSize: 10);

      await list.refresh();
      expect(list.hasMore, isTrue);
      await list.loadMore();

      expect(list.items.length, 15);
      expect(list.hasMore, isFalse);
    });

    test('loadMore is a no-op once the end is reached', () async {
      final src = _FakeSource(5);
      final list = PagedList<int>(fetchPage: src.fetch, pageSize: 10);

      await list.refresh();
      await list.loadMore();
      await list.loadMore();

      expect(src.calls.length, 1, reason: 'must not keep hitting the API');
    });

    test('overlapping loadMore calls only fire one request', () async {
      final src = _FakeSource(100, delay: const Duration(milliseconds: 20));
      final list = PagedList<int>(fetchPage: src.fetch, pageSize: 10);
      await list.refresh();

      // A scroll listener fires on every pixel — it must not stampede.
      await Future.wait([list.loadMore(), list.loadMore(), list.loadMore()]);

      expect(src.calls.length, 2, reason: 'refresh + exactly one loadMore');
      expect(list.items.length, 20);
    });

    test('refresh replaces rather than appends', () async {
      final src = _FakeSource(100);
      final list = PagedList<int>(fetchPage: src.fetch, pageSize: 10);

      await list.refresh();
      await list.loadMore();
      expect(list.items.length, 20);

      await list.refresh();
      expect(list.items.length, 10);
    });

    test('a prepended item does not push the next page past a row', () async {
      final src = _FakeSource(100);
      final list = PagedList<int>(fetchPage: src.fetch, pageSize: 10);

      await list.refresh();
      list.prepend(-1); // created locally; the server knows nothing about it

      await list.loadMore();

      expect(src.calls[1], (limit: 10, offset: 10),
          reason: 'the server has still only handed over 10 rows');
      expect(list.items, [-1, ...List.generate(20, (i) => i)],
          reason: 'row 10 must not be skipped');
    });

    test('a removed item does not make the next page repeat a row', () async {
      final src = _FakeSource(100);
      final list = PagedList<int>(fetchPage: src.fetch, pageSize: 10);

      await list.refresh();
      list.removeItem((v) => v == 0);

      await list.loadMore();

      expect(src.calls[1], (limit: 10, offset: 10));
      expect(list.items, List.generate(20, (i) => i).sublist(1),
          reason: 'row 9 must not arrive twice');
    });

    test('refresh puts the cursor back to zero after local edits', () async {
      final src = _FakeSource(100);
      final list = PagedList<int>(fetchPage: src.fetch, pageSize: 10);

      await list.refresh();
      list.prepend(-1);
      await list.refresh();
      await list.loadMore();

      expect(src.calls.last, (limit: 10, offset: 10));
      expect(list.items, List.generate(20, (i) => i));
    });
  });

  group('PagedList staleness', () {
    test('a slow first query cannot overwrite a newer one', () async {
      // The search box refreshes on every keystroke; the earlier, slower
      // response must not land on top of the later one.
      final completers = <Completer<List<int>>>[];
      final list = PagedList<int>(
        pageSize: 10,
        fetchPage: ({required limit, required offset}) {
          final c = Completer<List<int>>();
          completers.add(c);
          return c.future;
        },
      );

      final first = list.refresh();
      final second = list.refresh();
      completers[1].complete([99]);   // newer query answers first
      await second;
      completers[0].complete([1, 2, 3]); // older query answers late
      await first;

      expect(list.items, [99]);
    });
  });

  group('PagedList errors', () {
    test('a failing refresh surfaces the error and empties the list', () async {
      final list = PagedList<int>(
        fetchPage: ({required limit, required offset}) =>
            Future.error(StateError('boom')),
      );

      await list.refresh();

      expect(list.error, isA<StateError>());
      expect(list.items, isEmpty);
      expect(list.isLoading, isFalse);
    });

    test('a failing loadMore keeps the pages already shown', () async {
      var calls = 0;
      final list = PagedList<int>(
        pageSize: 2,
        fetchPage: ({required limit, required offset}) async {
          if (calls++ == 0) return [1, 2];
          throw StateError('boom');
        },
      );

      await list.refresh();
      await list.loadMore();

      expect(list.items, [1, 2], reason: 'must not blank the grid on error');
      expect(list.error, isA<StateError>());
    });

    test('a failed page stops the pager instead of retrying on every tick',
        () async {
      var calls = 0;
      final list = PagedList<int>(
        pageSize: 2,
        fetchPage: ({required limit, required offset}) async {
          if (calls++ == 0) return [1, 2];
          throw StateError('boom');
        },
      );

      await list.refresh();
      await list.loadMore();

      expect(list.hasMore, isFalse,
          reason: 'the grid spins and re-fires loadMore while hasMore is true');

      await list.loadMore();
      expect(calls, 2, reason: 'must not hammer an endpoint that just failed');
    });

    test('a failed refresh stops the pager too', () async {
      final list = PagedList<int>(
        fetchPage: ({required limit, required offset}) =>
            Future.error(StateError('boom')),
      );

      await list.refresh();

      expect(list.hasMore, isFalse);
    });
  });

  group('PagedList local mutation', () {
    late PagedList<int> list;

    setUp(() async {
      final src = _FakeSource(5);
      list = PagedList<int>(fetchPage: src.fetch, pageSize: 10);
      await list.refresh();
    });

    test('replaceItem swaps in place and notifies', () {
      var notified = 0;
      list.addListener(() => notified++);

      list.replaceItem((v) => v == 2, 42);

      expect(list.items, [0, 1, 42, 3, 4]);
      expect(notified, 1);
    });

    test('replaceItem on a missing item is a no-op', () {
      var notified = 0;
      list.addListener(() => notified++);

      list.replaceItem((v) => v == 999, 42);

      expect(list.items, [0, 1, 2, 3, 4]);
      expect(notified, 0);
    });

    test('removeItem drops it without a refetch', () {
      list.removeItem((v) => v == 0);
      expect(list.items, [1, 2, 3, 4]);
    });

    test('removeItem only notifies when something was removed', () {
      var notified = 0;
      list.addListener(() => notified++);

      list.removeItem((v) => v == 999);
      expect(notified, 0);

      list.removeItem((v) => v == 1);
      expect(notified, 1);
    });

    test('prepend puts a freshly created item first', () {
      list.prepend(-1);
      expect(list.items.first, -1);
    });

    test('items is not writable by callers', () {
      expect(() => list.items.add(9), throwsUnsupportedError);
    });
  });
}
