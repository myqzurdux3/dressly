import 'package:dressly/services/api_client.dart';
import 'package:dressly/services/polling.dart';
import 'package:flutter_test/flutter_test.dart';

/// The render and stylist waits: stop when the screen is gone, and survive a
/// dropped request instead of abandoning a render that is still running.
void main() {
  Future<int> run(
    List<Object> script, {
    bool Function()? cancelled,
    int maxRounds = 20,
  }) {
    final queue = List.of(script);
    return pollUntil<int>(
      fetch: () async {
        final next = queue.removeAt(0);
        if (next is int) return next;
        throw next;
      },
      isDone: (v) => v >= 100,
      initial: -1,
      every: Duration.zero,
      maxRounds: maxRounds,
      cancelled: cancelled,
    );
  }

  final offline = ApiException(0, 'offline');

  test('returns as soon as the value is done', () async {
    expect(await run([1, 2, 100, 3]), 100);
  });

  test('tolerates up to two transport errors in a row', () async {
    expect(await run([1, offline, offline, 100]), 100);
  });

  test('the counter resets after a success', () async {
    expect(await run([offline, offline, 1, offline, offline, 100]), 100);
  });

  test('a third transport error in a row gives up', () async {
    await expectLater(run([offline, offline, offline, 100]), throwsA(offline));
  });

  test('a server error is not retried', () async {
    final denied = ApiException(500, 'boom');
    await expectLater(run([denied, 100]), throwsA(denied));
  });

  test('stops when cancelled, with the last value seen', () async {
    var calls = 0;
    final queue = [1, 2, 3, 100];
    final got = await pollUntil<int>(
      fetch: () async {
        calls++;
        return queue.removeAt(0);
      },
      isDone: (v) => v >= 100,
      initial: -1,
      every: Duration.zero,
      maxRounds: 20,
      cancelled: () => calls >= 2,
    );
    expect(got, 2);
    expect(calls, 2);
  });

  test('cancelled before the first fetch returns the initial value', () async {
    expect(await run([100], cancelled: () => true), -1);
  });

  test('gives back the latest value after maxRounds', () async {
    expect(await run([1, 2, 3, 4], maxRounds: 3), 3);
  });
}
