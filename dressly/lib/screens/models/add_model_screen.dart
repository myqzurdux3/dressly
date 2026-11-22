import 'dart:io';

import 'package:flutter/material.dart';

import '../../design/ds.dart';
import '../../l10n/app_text.dart';

import '../../app.dart';
import '../../widgets/error_toast.dart';
import '../../widgets/photo_source_sheet.dart';

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


  Future<void> _pickImage() async {
    final path = await pickPhotoPath(context);
    // The picker can outlive the screen (back pressed while it was open).
    if (path != null && mounted) setState(() => _images.add(path));
  }

  Future<void> _replace(int i) async {
    final path = await pickPhotoPath(context);
    if (path != null && mounted) setState(() => _images[i] = path);
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      toastKey('form.nameRequired');
      return;
    }
    if (_images.length < 2) {
      toastKey('form.frontBackRequired');
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
      toastError(e, prefixKey: 'form.saveFailed');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

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
