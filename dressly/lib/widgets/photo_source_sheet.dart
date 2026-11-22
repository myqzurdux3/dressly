import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../design/ds.dart';
import '../l10n/app_text.dart';
import 'error_toast.dart';

/// Asks camera or gallery in a Dressly sheet, then returns the chosen photo's
/// local path, or null if the user cancelled.
///
/// Shared by the cloth and model forms. A picker failure (permission denied,
/// plugin error) is shown as a `form.photoError` toast and yields null.
Future<String?> pickPhotoPath(BuildContext context) async {
  final source = await showDsSheet<String>(
    context,
    title: tr(context, 'form.pictures'),
    child: Builder(
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (value, icon, key) in [
            ('camera', Icons.photo_camera_outlined, 'form.takePhoto'),
            ('gallery', Icons.photo_library_outlined, 'form.chooseGallery'),
          ])
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(icon, color: ctx.ds.colors.accent),
              title: Text(tr(ctx, key), style: ctx.ds.typo.bodyStrong),
              onTap: () => Navigator.pop(ctx, value),
            ),
        ],
      ),
    ),
  );
  if (source == null) return null;
  try {
    if (source == 'camera') {
      final x = await ImagePicker().pickImage(
        source: ImageSource.camera,
        imageQuality: 92,
      );
      return x?.path;
    }
    final result = await FilePicker.platform.pickFiles(type: FileType.image);
    return result?.files.single.path;
  } catch (e) {
    if (context.mounted) {
      showErrorToast(context, e, prefixKey: 'form.photoError');
    }
    return null;
  }
}
