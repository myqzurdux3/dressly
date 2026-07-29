import 'dart:async';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;

/// [HttpFileService] with a deadline.
///
/// `flutter_cache_manager` runs at most ten downloads at once and queues the
/// rest. It releases a slot in a `finally`, which is correct for a request that
/// fails — but a request that simply never answers never reaches the `finally`
/// at all, because the `await for` over its response stream never completes.
/// There is no timeout anywhere on that path.
///
/// So one stalled connection costs a permanent slot. Ten of them — easy on a
/// mobile network, where NAT silently drops idle sockets — and the app stops
/// loading images for good, while the server's log shows every request it
/// received completing normally. That is exactly the shape of the failure this
/// was written for.
///
/// A timeout turns a hung request into a failed one, which the queue already
/// knows how to handle: the slot is freed and the next image starts.
class TimeoutFileService extends FileService {
  TimeoutFileService({
    required http.Client httpClient,
    this.timeout = const Duration(seconds: 10),
  }) : _inner = HttpFileService(httpClient: httpClient);

  final HttpFileService _inner;

  /// Ten seconds. Long enough for a large image on a slow link, short enough
  /// that a dead connection is not felt for long. It was twenty, which is how
  /// long the app appeared frozen when one stalled.
  final Duration timeout;

  @override
  Future<FileServiceResponse> get(String url,
      {Map<String, String>? headers}) async {
    try {
      return await _attempt(url, headers);
    } catch (_) {
      // One retry, on a fresh connection. A kept-alive socket can be dropped by
      // the network without either end being told; the request sent down it
      // then goes nowhere until the deadline. Reissuing usually just works, and
      // an image that fails outright leaves a visible gap in the grid.
      return _attempt(url, headers);
    }
  }

  Future<FileServiceResponse> _attempt(
      String url, Map<String, String>? headers) {
    return _inner.get(url, headers: headers).timeout(
      timeout,
      onTimeout: () => throw TimeoutException(
          'image request exceeded ${timeout.inSeconds}s', timeout),
    );
  }
}
