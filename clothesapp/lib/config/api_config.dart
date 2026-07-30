/// Backend connection configuration.
///
/// `127.0.0.1` won't reach the host from a device. Use:
///  - Linux desktop / web debug: http://127.0.0.1:8000
///  - Android emulator:          http://10.0.2.2:8000
///  - Physical device on the LAN: `http://<this machine's LAN IP>:8000`
///  - Public server:              `https://<domain>`
const String apiBaseUrl = 'https://dressly.xyz';

/// SHA-256 fingerprint of the server's certificate, lower-case hex, no colons.
///
/// EMPTY, and it should stay empty now that the app talks to dressly.xyz
/// through Cloudflare: the certificate the phone sees is Cloudflare's, issued
/// by a real authority and rotated by them on their own schedule. Pinning it
/// would break the app without warning on the day they rotate it, and normal
/// certificate validation already covers this hop.
///
/// Set it only if the app ever connects straight to a self-signed origin, which
/// nothing trusts by itself. `python scripts/make_cert.py` prints the value.
/// Regenerating the certificate changes the pin — update both together or the
/// app refuses to connect.
///
/// Note this pins the phone-to-Cloudflare hop only. Cloudflare to the origin is
/// a separate connection, secured by the Cloudflare SSL mode (Full here), not
/// by anything in this file.
const String apiCertSha256 = '';

/// Whether the app talks TLS at all.
bool get apiUsesTls => apiBaseUrl.startsWith('https://');

String apiUrl(String path) {
  if (path.startsWith('http')) return path;
  return '$apiBaseUrl${path.startsWith('/') ? path : '/$path'}';
}

/// Full URL for an image path returned by the API (e.g. "/images/3/front_0_cutout.webp").
String imageUrl(String? path) => apiUrl(path ?? '');
