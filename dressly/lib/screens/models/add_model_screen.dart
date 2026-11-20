import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../design/ds.dart';
import '../../l10n/app_text.dart';

import '../../app.dart';

/// Add a new model (a person/avatar) with a front + back picture. Mirrors the
/// add-cloth flow: background removal runs on upload, and the user reviews it
/// afterwards in the model review screen.
class AddModelScreen extends StatefulWidget {
  const AddModelScreen({super.key});

  @override
  State<AddModelScreen> createState() => _AddModelScreenState();
}

class _AddModelScreenState extends State<AddModelScreen> {
  final _name = TextEditingController();
  final List<String> _images = [];
  String _gender = ''; // '' unspecified | 'male' | 'female'
  bool _saving = false;

  /// Let the user take a photo with the camera or pick a file from the gallery,
  /// then return its path (or null if cancelled).
  Future<String?> _pickFilePath() async {
    final source = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera),
              title: Text(tr(context, 'form.takePhoto')),
              onTap: () => Navigator.pop(ctx, 'camera'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: Text(tr(context, 'form.chooseGallery')),
              onTap: () => Navigator.pop(ctx, 'gallery'),
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
      final r = await FilePicker.platform.pickFiles(type: FileType.image);
      return r?.files.single.path;
    } catch (e) {
      if (mounted) _toast('${tr(context, 'form.photoError')}: $e');
      return null;
    }
  }

  Future<void> _pickImage() async {
    final path = await _pickFilePath();
    if (path != null) setState(() => _images.add(path));
  }

  Future<void> _replace(int i) async {
    final path = await _pickFilePath();
    if (path != null) setState(() => _images[i] = path);
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      _toast(tr(context, 'form.nameRequired'));
      return;
    }
    if (_images.length < 2) {
      _toast(tr(context, 'form.frontBackRequired'));
      return;
    }
    setState(() => _saving = true);
    try {
      final svc = modelsServiceOf(context);
      await svc.create(
        name: _name.text.trim(),
        gender: _gender,
        images: _images.map((p) => File(p)).toList(),
      );
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) _toast('${tr(context, 'form.saveFailed')}: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _toast(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final muted = ds.typo.label.copyWith(color: ds.colors.textMuted);
    return DsSubPage(
      title: tr(context, 'models.addTitle'),
      bottom: DsButton(
        label: tr(context, 'models.saveModel'),
        expand: true,
        loading: _saving,
        onPressed: _saving ? null : _save,
      ),
      children: [
        DsSectionTitle(tr(context, 'form.name')),
        TextField(
          controller: _name,
          decoration: InputDecoration(hintText: tr(context, 'models.nameHint')),
        ),
        DsSectionTitle(tr(context, 'models.gender')),
        DsSegment<String>(
          options: [
            ('', tr(context, 'models.genderUnspecified')),
            ('male', tr(context, 'models.genderMale')),
            ('female', tr(context, 'models.genderFemale')),
          ],
          value: _gender,
          onChanged: (v) => setState(() => _gender = v),
        ),
        DsSectionTitle(tr(context, 'form.pictures')),
        Text(tr(context, 'form.picHintGarmentAdd'), style: muted),
        SizedBox(height: ds.space.s),
        Wrap(
          spacing: ds.space.s,
          runSpacing: ds.space.s,
          children: [
            for (final (i, path) in _images.indexed)
              _Thumb(
                path: path,
                label: i == 0
                    ? tr(context, 'models.frontReq')
                    : i == 1
                    ? tr(context, 'models.backReq')
                    : tr(context, 'models.extra'),
                onTap: () => _replace(i),
              ),
          ],
        ),
        SizedBox(height: ds.space.s),
        Align(
          alignment: Alignment.centerLeft,
          child: DsButton(
            label: _images.isEmpty
                ? tr(context, 'models.pickFront')
                : _images.length == 1
                ? tr(context, 'models.pickBack')
                : tr(context, 'models.pickExtra'),
            icon: Icons.add_a_photo,
            kind: DsButtonKind.secondary,
            onPressed: _pickImage,
          ),
        ),
      ],
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.path, required this.label, required this.onTap});
  final String path;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 130,
        height: 170,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: ds.colors.surface,
          borderRadius: ds.shape.cardRadius,
        ),
        child: Stack(
          children: [
            // Decode at tile size: a camera capture is ~12 MP, which would
            // otherwise sit in memory in full for a 130 px box.
            Image.file(
              File(path),
              width: 130,
              height: 170,
              fit: BoxFit.cover,
              cacheWidth:
                  (130 * (MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0))
                      .round(),
            ),
            Positioned(
              top: ds.space.xs,
              left: ds.space.xs,
              child: DsBadge(text: label),
            ),
          ],
        ),
      ),
    );
  }
}
