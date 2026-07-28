/// Backend connection configuration.
///
/// `127.0.0.1` won't reach the host from a device. Use:
///  - Linux desktop / web debug: http://127.0.0.1:8000
///  - Android emulator:          http://10.0.2.2:8000
///  - Physical device:           `http://<this machine's LAN IP>:8000`
///
/// Set to this PC's LAN IP so a physical phone on the same Wi-Fi can connect.
/// Re-check it with `hostname -I` — it changes if the router reassigns it.
const String apiBaseUrl = 'http://192.168.1.30:8000';

String apiUrl(String path) {
  if (path.startsWith('http')) return path;
  return '$apiBaseUrl${path.startsWith('/') ? path : '/$path'}';
}

/// Full URL for an image path returned by the API (e.g. "/images/3/front_0_cutout.png").
String imageUrl(String? path) => apiUrl(path ?? '');