import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

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
        child: Column(mainAxisSize: MainAxisSize.min, children: [
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
        ]),
      ),
    );
    if (source == null) return null;
    try {
      if (source == 'camera') {
        final x = await ImagePicker()
            .pickImage(source: ImageSource.camera, imageQuality: 92);
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
          images: _images.map((p) => File(p)).toList());
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) _toast('${tr(context, 'form.saveFailed')}: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'models.addTitle'))),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr(context, 'form.name'),
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 8),
          TextField(
            controller: _name,
            decoration: InputDecoration(
                border: const OutlineInputBorder(), hintText: tr(context, 'models.nameHint')),
          ),
          const SizedBox(height: 24),
          Text(tr(context, 'models.gender'),
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                  value: '', label: Text(tr(context, 'models.genderUnspecified'))),
              ButtonSegment(
                  value: 'male', label: Text(tr(context, 'models.genderMale'))),
              ButtonSegment(
                  value: 'female', label: Text(tr(context, 'models.genderFemale'))),
            ],
            selected: {_gender},
            onSelectionChanged: (s) => setState(() => _gender = s.first),
          ),
          const SizedBox(height: 24),
          Text(tr(context, 'form.pictures'),
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 4),
          Text(tr(context, 'form.picHintGarmentAdd'),
              style: TextStyle(color: Colors.grey, fontSize: 12)),
          const SizedBox(height: 8),
          Wrap(spacing: 12, runSpacing: 12, children: [
            ..._images.asMap().entries.map((e) {
              final i = e.key;
              return _Thumb(
                path: e.value,
                label: i == 0
                    ? tr(context, 'models.frontReq')
                    : i == 1
                        ? tr(context, 'models.backReq')
                        : tr(context, 'models.extra'),
                onTap: () => _replace(i),
              );
            }),
          ]),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _pickImage,
            icon: const Icon(Icons.add_a_photo),
            label: Text(_images.isEmpty
                ? tr(context, 'models.pickFront')
                : _images.length == 1
                    ? tr(context, 'models.pickBack')
                    : tr(context, 'models.pickExtra')),
          ),
          const SizedBox(height: 28),
          SizedBox(
            width: double.infinity,
            height: 56,
            child: FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      height: 22,
                      width: 22,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(tr(context, 'models.saveModel'),
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ),
          ),
        ]),
      ),
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
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 130,
        height: 170,
        decoration: BoxDecoration(
          color: Colors.grey[900],
          border: Border.all(color: Colors.grey[700]!),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Stack(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(11),
            // Decode at tile size: a camera capture is ~12 MP, which would
            // otherwise sit in memory in full for a 130 px box.
            child: Image.file(File(path),
                width: 130, height: 170, fit: BoxFit.cover,
                cacheWidth: (130 *
                        (MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0))
                    .round()),
          ),
          Positioned(
            top: 4,
            right: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                  color: Colors.black54, borderRadius: BorderRadius.circular(6)),
              child: Text(label, style: const TextStyle(fontSize: 12)),
            ),
          ),
        ]),
      ),
    );
  }
}