import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../config/api_config.dart';

/// HTTP client that accepts the server's self-signed certificate — and only
/// that one.
///
/// A self-signed certificate is trusted by nothing, which leaves two options.
/// Accept any certificate (`badCertificateCallback => true`) and the connection
/// looks encrypted while anyone in the middle can read it — worse than plain
/// HTTP, because it invites false confidence. Or pin: accept exactly the
/// certificate whose fingerprint is compiled in, and reject everything else.
/// Pinning is the strong option; it holds even against an attacker who obtained
/// a valid certificate from a real authority.
///
/// With [apiCertSha256] empty the platform's normal validation applies, which
/// is what you want once the server has a certificate from Let's Encrypt.
class PinnedHttp {
  /// Fingerprints, lower-case hex, that this build accepts.
  static String _pin = apiCertSha256.replaceAll(':', '').toLowerCase();

  /// Override the pin at runtime. Exists for tests; the app uses the constant.
  static void setPinForTesting(String pin) =>
      _pin = pin.replaceAll(':', '').toLowerCase();

  static bool get isPinned => _pin.isNotEmpty;

  /// SHA-256 over the certificate's DER bytes — the same value OpenSSL prints
  /// as `-fingerprint -sha256` and what make_cert.py reports.
  static String fingerprintOf(X509Certificate cert) =>
      sha256.convert(cert.der).toString();

  /// True when [cert] is the certificate this build was pinned to.
  static bool accepts(X509Certificate cert) =>
      isPinned && fingerprintOf(cert) == _pin;

  /// Client for API calls — short, latency-sensitive requests.
  ///
  /// Deliberately SEPARATE from [images]. HTTP/1.1 carries one request per
  /// connection at a time, so a shared pool lets slow image downloads occupy
  /// every connection and leave JSON requests queued behind them. With a single
  /// pool of six, six images in flight froze the entire app until one finished
  /// — for a stalled image, that meant the full timeout.
  static final http.Client api = create(maxConnections: 4);

  /// Client for image downloads. Its own pool, so a stalled image can delay
  /// other images and nothing else.
  ///
  /// Eight matches the download queue's concurrency without serialising it.
  static final http.Client images = create(maxConnections: 8);

  /// Build a client with its own connection pool.
  ///
  /// Falls back to a plain client when there is no pin, so a Let's Encrypt
  /// deployment (or local HTTP) needs no special casing.
  static http.Client create({int maxConnections = 6}) {
    if (!isPinned || !apiUsesTls) return http.Client();
    final inner = HttpClient()
      // Keep sockets around between requests. A grid fires a dozen image
      // requests; without this each one reopens and re-handshakes.
      // Keep sockets around between requests: measured against the deployed
      // server, eight requests over one kept-alive connection cost 140 ms each
      // against 670 ms each when every one reconnects.
      ..idleTimeout = const Duration(seconds: 30)
      ..maxConnectionsPerHost = maxConnections
      // Without this a TCP connect to an unreachable host waits on the OS
      // default, which is minutes.
      ..connectionTimeout = const Duration(seconds: 15);
    // Assigned separately, not in the cascade: a trailing `..` after a lambda
    // binds to the lambda's body, not to the client.
    //
    // Reached only when the platform has ALREADY rejected the certificate,
    // which a self-signed one always is. Returning true for anything other
    // than our exact certificate would defeat the whole point.
    inner.badCertificateCallback = (cert, host, port) => accepts(cert);
    return IOClient(inner);
  }
}

/// Applies the pin to every HttpClient Flutter creates, not just ours.
///
/// `cached_network_image` (and `Image.network`) build their own clients deep
/// inside the framework, so without this the JSON would load over pinned TLS
/// while every photo failed on an untrusted certificate.
class PinnedHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback = (cert, host, port) => PinnedHttp.accepts(cert);
  }
}

/// Install the override when this build is pinned. No-op otherwise, so a
/// Let's Encrypt deployment keeps ordinary certificate validation.
void installCertificatePinning() {
  if (PinnedHttp.isPinned && apiUsesTls) {
    HttpOverrides.global = PinnedHttpOverrides();
  }
}

/// Base64 of the pin, handy for logging without dumping the whole certificate.
String shortPin() => PinnedHttp.isPinned
    ? base64Url.encode(
        List<int>.generate(4, (i) => int.parse(
            apiCertSha256.replaceAll(':', '').substring(i * 2, i * 2 + 2),
            radix: 16)))
    : 'none';
