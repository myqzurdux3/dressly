/// Backend connection configuration.
///
/// `127.0.0.1` won't reach the host from a device. Use:
///  - Linux desktop / web debug: http://127.0.0.1:8000
///  - Android emulator:          http://10.0.2.2:8000
///  - Physical device on the LAN: `http://<this machine's LAN IP>:8000`
///  - Public server:              `https://<host>:8000`
const String apiBaseUrl = 'https://193.243.147.15:8000';

/// SHA-256 fingerprint of the server's certificate, lower-case hex, no colons.
///
/// Only needed while the server uses a self-signed certificate — which nothing
/// trusts, so the app has to say which single certificate it accepts. That is
/// what makes a self-signed setup actually safe: the connection cannot be
/// intercepted, not even by someone holding a certificate from a real
/// authority, because only this exact one is accepted.
///
/// Get it from `python scripts/make_cert.py`, which prints it when generating
/// the certificate. Regenerating the certificate changes the pin — update both
/// at the same time or the app will refuse to connect.
///
/// Leave EMPTY once the server has a real certificate (Let's Encrypt behind
/// Caddy/nginx): normal certificate validation then applies, with no pin to
/// keep in sync.
const String apiCertSha256 =
    '80e1dd3c37849580e2d9f76fb47ae7be85dbfa3f8754e8832e94612f5320fa9f';

/// Whether the app talks TLS at all.
bool get apiUsesTls => apiBaseUrl.startsWith('https://');

String apiUrl(String path) {
  if (path.startsWith('http')) return path;
  return '$apiBaseUrl${path.startsWith('/') ? path : '/$path'}';
}

/// Full URL for an image path returned by the API (e.g. "/images/3/front_0_cutout.webp").
String imageUrl(String? path) => apiUrl(path ?? '');
