import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;

import '../l10n/app_text.dart';
import 'app_image.dart';

/// Download the generated outfit image to a user-chosen file.
/// Returns the saved path, or null if the user cancelled.
/// Pass the display URL (with cache-bust) so any stale image isn't fetched.
Future<String?> saveOutfitImage(BuildContext context, String displayUrl) async {
  if (displayUrl.isEmpty) return null;
  try {
    final resp = await http.get(Uri.parse(displayUrl));
    if (resp.statusCode != 200) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr(context, 'viewer.downloadFailedHttp')
              .replaceFirst('{code}', '${resp.statusCode}'))),
        );
      }
      return null;
    }
    final Uint8List bytes = resp.bodyBytes;
    final saveTitle = context.mounted ? tr(context, 'viewer.saveTitle') : 'Save outfit';
    final path = await FilePicker.platform.saveFile(
      dialogTitle: saveTitle,
      fileName: 'outfit.png',
      bytes: bytes,
    );
    if (path != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr(context, 'viewer.saved'))),
      );
    }
    return path;
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('${tr(context, 'viewer.downloadFailed')}: $e')));
    }
    return null;
  }
}

/// Fullscreen, pinch-to-zoom view of a generated outfit, with a Download
/// button in the app bar. Pass the display URL (cache-busted).
void showOutfitFullscreen(BuildContext context, String displayUrl) {
  Navigator.of(context).push(
    PageRouteBuilder(
      opaque: false,
      barrierColor: Colors.black,
      pageBuilder: (_, __, ___) => _FullscreenOutfit(url: displayUrl),
    ),
  );
}

class _FullscreenOutfit extends StatelessWidget {
  const _FullscreenOutfit({required this.url});
  final String url;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black54,
        actions: [
          IconButton(
            icon: const Icon(Icons.download),
            tooltip: tr(context, 'viewer.download'),
            onPressed: () => saveOutfitImage(context, url),
          ),
        ],
      ),
      body: InteractiveViewer(
        minScale: 0.5,
        maxScale: 6,
        child: Center(
          child: AppImage(url: url, fit: BoxFit.contain),
        ),
      ),
    );
  }
}