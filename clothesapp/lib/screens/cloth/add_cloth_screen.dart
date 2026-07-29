import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../app.dart';
import '../../config/api_config.dart';
import '../../l10n/app_text.dart';
import '../../models/cloth.dart';
import '../../services/clothes_service.dart';
import '../../widgets/app_image.dart';
import '../../widgets/color_row.dart';
import '../../widgets/image_review.dart';
import '../../widgets/image_slot.dart';
import 'cloth_detail_screen.dart';
import 'photo_edit_screen.dart';

/// Reused for both adding a new cloth and editing an existing one. When
/// [initial] is non-null the form is pre-populated and saving PUTs instead of
/// POSTing — switching an item between add and edit mode in one screen keeps
/// the field layout in lockstep.
class ClothFormScreen extends StatefulWidget {
  const ClothFormScreen({super.key, this.initial});

  final Cloth? initial;

  bool get isEdit => initial != null;

  @override
  State<ClothFormScreen> createState() => _ClothFormScreenState();
}

class _ClothFormScreenState extends State<ClothFormScreen> {
  final _name = TextEditingController();

  String? _category;
  String _cut = 'normal';
  int _score = 0;
  final List<ClothColor> _colors = [];
  final List<String> _tags = [];
  /// Paths the user picked THIS session (front, back, then extras). Used only
  /// in ADD mode — in edit mode images are managed live against the server.
  final List<String> _newImages = [];
  /// Edit mode only: the cloth's current photos. Kept mutable so replace / add
  /// / delete (which hit the server and return the updated cloth) refresh the
  /// thumbnails immediately.
  List<ClothImage> _existingImages = [];
  bool _imgBusy = false;
  int _scoreBeforeEdit = 0;

  TextEditingController? _tagField;
  TextEditingController? _brandField;

  List<String> _brandSuggestions = [];
  List<String> _tagSuggestions = [];
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final c = widget.initial;
    if (c != null) {
      _name.text = c.name;
      _category = c.category.isEmpty ? null : c.category;
      _cut = c.cut.isEmpty ? 'normal' : c.cut;
      _colors.addAll(c.colors);
      _tags.addAll(c.customTags);
      _scoreBeforeEdit = c.score;
      _score = c.score;
      _existingImages = [...c.images];
    }
    _loadAutocomplete();
  }

  @override
  void dispose() {
    _name.dispose();
    // NOTE: _brandField / _tagField are owned by their Autocomplete widgets
    // (assigned in fieldViewBuilder). Autocomplete disposes them itself — if we
    // dispose them here too, its own dispose runs against an already-disposed
    // controller and throws "A TextEditingController was used after being
    // disposed" when leaving the edit screen.
    super.dispose();
  }

  Future<void> _loadAutocomplete() async {
    final svc = clothesServiceOf(context);
    try {
      final brands = await svc.autocompleteBrands();
      final tags = await svc.autocompleteTags();
      if (mounted) {
        setState(() {
          _brandSuggestions = brands;
          _tagSuggestions = tags;
        });
      }
    } catch (_) {}
  }

  Future<void> _pickImage() async {
    final path = await _pickFilePath();
    if (path != null) setState(() => _newImages.add(path));
  }

  // ---- Edit-mode live image management (server-backed) ----

  /// Lets the user take a photo with the camera or pick a file, then returns
  /// its local path (or null if cancelled).
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
      final result = await FilePicker.platform.pickFiles(type: FileType.image);
      return result?.files.single.path;
    } catch (e) {
      _toastKey('form.photoError', e);
      return null;
    }
  }

  /// Open the crop & rotate editor for an existing photo (edit mode).
  Future<void> _editPhoto(ClothImage img) async {
    if (_imgBusy) return;
    final updated = await Navigator.push<Cloth>(
      context,
      MaterialPageRoute(
        builder: (_) => PhotoEditScreen(clothId: widget.initial!.id, image: img),
      ),
    );
    if (updated != null && mounted) {
      setState(() => _existingImages = [...updated.images]);
    }
  }

  /// Replace an existing photo with a freshly-picked file (re-runs bg removal
  /// on the server), then ask whether to keep the cut-out or the original.
  Future<void> _replaceExistingImage(int imageId) async {
    if (_imgBusy) return;
    final svc = clothesServiceOf(context);
    final path = await _pickFilePath();
    if (path == null) return;
    setState(() => _imgBusy = true);
    try {
      final updated =
          await svc.replaceImage(widget.initial!.id, imageId, File(path));
      if (!mounted) return;
      setState(() => _existingImages = [...updated.images]);
      await _reviewNewImage(imageId);
    } catch (e) {
      _toastKey('form.updateFailed', e);
    } finally {
      if (mounted) setState(() => _imgBusy = false);
    }
  }

  Future<void> _addImageNow() async {
    if (_imgBusy) return;
    final svc = clothesServiceOf(context);
    final path = await _pickFilePath();
    if (path == null) return;
    setState(() => _imgBusy = true);
    try {
      final updated = await svc.addImage(widget.initial!.id, File(path));
      if (!mounted) return;
      setState(() => _existingImages = [...updated.images]);
      // The newly-added photo is the last one; review it.
      if (updated.images.isNotEmpty) {
        await _reviewNewImage(updated.images.last.id);
      }
    } catch (e) {
      _toastKey('form.addFailed', e);
    } finally {
      if (mounted) setState(() => _imgBusy = false);
    }
  }

  ClothImage? _imgById(List<ClothImage> images, int id) {
    for (final im in images) {
      if (im.id == id) return im;
    }
    return null;
  }

  /// Crop decision that SHOWS the cut-out and the original before you pick.
  Future<void> _decideCrop(ClothesService svc, int imageId) async {
    final img = _imgById(_existingImages, imageId);
    if (img == null || !mounted) return;
    final keepCutout = await showCropDecision(
      context,
      cutoutUrl: img.cutoutPreview,
      originalUrl: img.originalPreview,
      tolerance: img.bgTolerance,
      // Let the user try Soft/Balanced/Strong right in the crop decision.
      onChangeTolerance: (level) async {
        final c = await svc.redoBackground(widget.initial!.id, imageId,
            tolerance: level);
        if (mounted) setState(() => _existingImages = [...c.images]);
        // Feeds the same comparison panel as above, so the same size.
        return _imgById(c.images, imageId)?.cutoutPreview;
      },
    );
    if (keepCutout == null || !mounted) return;
    try {
      if (keepCutout) {
        await svc.acceptImage(widget.initial!.id, imageId);
      } else {
        await svc.rejectImage(widget.initial!.id, imageId);
      }
      final refreshed = await svc.get(widget.initial!.id);
      if (mounted) setState(() => _existingImages = [...refreshed.images]);
    } catch (e) {
      _toastKey('form.bgChoiceFailed', e);
    }
  }

  /// Guided review of a freshly added/replaced photo:
  /// 1) decide crop (with preview), 2) optionally enhance (Auto/AI + preview).
  Future<void> _reviewNewImage(int imageId) async {
    final svc = clothesServiceOf(context);
    await _decideCrop(svc, imageId);
    if (!mounted) return;
    final mode = await showEnhanceChoice(context);
    if (mode == null) return;
    await _runEnhance(svc, imageId, mode);
  }

  /// Enhance an existing photo on demand (from the tile's ✨ button).
  Future<void> _enhanceExisting(int imageId) async {
    if (_imgBusy) return;
    final svc = clothesServiceOf(context);
    final mode = await showEnhanceChoice(context);
    if (mode == null) return;
    await _runEnhance(svc, imageId, mode);
  }

  /// Run enhancement, show the GENERATED result (before/after) and let the user
  /// keep, discard, or step up to a better AI model. Keeping applies it as-is —
  /// no second crop decision is forced.
  Future<void> _runEnhance(ClothesService svc, int imageId, String mode) async {
    if (!mounted) return;
    setState(() => _imgBusy = true);
    try {
      var tier = 'flex';
      while (true) {
        await svc.enhanceImage(widget.initial!.id, imageId, mode, tier: tier);
        final c = await svc.pollEnhance(widget.initial!.id, imageId);
        if (mounted) setState(() => _existingImages = [...c.images]);
        final img = _imgById(c.images, imageId);
        if (img == null) return;
        if (img.enhanceStatus == 'failed' || img.enhancedUrl.isEmpty) {
          _toastKey('form.enhanceFailedShort');
          return;
        }
        if (!mounted) return;
        final choice = await showEnhancePreview(context,
            currentUrl: img.displayPreviewUrl ?? img.originalPreview,
            enhancedUrl: img.enhancedPreview,
            method: mode,
            nextTier: mode == 'ai' ? img.enhanceNextTier : null);
        if (choice == 'upgrade' && img.enhanceNextTier != null) {
          tier = img.enhanceNextTier!;
          continue; // regenerate with the better model
        }
        if (choice == 'keep') {
          final c2 = await svc.acceptEnhance(widget.initial!.id, imageId);
          if (mounted) setState(() => _existingImages = [...c2.images]);
          // No forced crop decision here — the generated image is kept as-is.
        } else {
          final c2 = await svc.rejectEnhance(widget.initial!.id, imageId);
          if (mounted) setState(() => _existingImages = [...c2.images]);
        }
        return;
      }
    } catch (e) {
      _toastKey('form.enhanceFailed', e);
    } finally {
      if (mounted) setState(() => _imgBusy = false);
    }
  }

  Future<void> _deleteExistingImage(int imageId) async {
    if (_imgBusy) return;
    setState(() => _imgBusy = true);
    try {
      final updated = await clothesServiceOf(context)
          .deleteImage(widget.initial!.id, imageId);
      if (!mounted) return;
      setState(() => _existingImages = [...updated.images]);
      _toastKey('form.pictureRemoved');
    } catch (e) {
      _toastKey('form.removeFailed', e);
    } finally {
      if (mounted) setState(() => _imgBusy = false);
    }
  }

  void _addColor() =>
      setState(() => _colors.add(ClothColor(color: 'Black', dominance: 'part')));

  bool _detectingColors = false;

  /// Ask the server to detect the garment's colors from its cut-out and merge
  /// the suggestions in (skipping ones already listed). The user edits freely.
  Future<void> _detectColors() async {
    if (_detectingColors) return;
    setState(() => _detectingColors = true);
    try {
      final detected =
          await clothesServiceOf(context).detectColors(widget.initial!.id);
      if (!mounted) return;
      if (detected.isEmpty) {
        _toastKey('form.noColors');
        return;
      }
      final existing = _colors.map((c) => c.color.toLowerCase()).toSet();
      final added = detected
          .where((d) => !existing.contains(d.color.toLowerCase()))
          .toList();
      setState(() => _colors.addAll(added));
      _toast(added.isEmpty
          ? tr(context, 'form.colorsAlready')
          : tr(context, 'form.colorsAdded'));
    } catch (e) {
      _toastKey('form.detectFailed', e);
    } finally {
      if (mounted) setState(() => _detectingColors = false);
    }
  }

  // Accepts one or several comma-separated tags at once.
  void _addTag(String raw) {
    for (final part in raw.split(',')) {
      final t = part.toLowerCase().trim();
      if (t.isNotEmpty && !_tags.contains(t)) {
        setState(() => _tags.add(t));
      }
    }
  }

  /// Shoes / bags / accessories: one photo is enough and extra angles are
  /// optional. Regular garments still need a front + back pair.
  bool get _multiAngle => isMultiAngleCategory(_category);

  String _picturesHint(bool isEdit) {
    if (_multiAngle) {
      return tr(context,
          isEdit ? 'form.picHintMultiEdit' : 'form.picHintMultiAdd');
    }
    return tr(context,
        isEdit ? 'form.picHintGarmentEdit' : 'form.picHintGarmentAdd');
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      _toastKey('form.nameRequired');
      return;
    }
    if (_category == null) {
      _toastKey('form.categoryRequired');
      return;
    }
    final minImages = _multiAngle ? 1 : 2;
    if (!widget.isEdit && _newImages.length < minImages) {
      _toast(_multiAngle
          ? tr(context, 'form.minOnePicture')
          : tr(context, 'form.frontBackRequired'));
      return;
    }
    // No cut for shoes / bags / accessories — send it empty so it's not stored.
    final cut = categoryHasCut(_category) ? _cut : '';
    setState(() => _saving = true);
    try {
      final svc = clothesServiceOf(context);
      final Cloth saved;
      if (widget.isEdit) {
        // Images are already saved live (replace/add/delete against the
        // server); the metadata PUT only carries the text fields.
        saved = await svc.update(
          widget.initial!.id,
          ClothUpdate(
            name: _name.text.trim(),
            brand: (_brandField?.text ?? '').trim(),
            cut: cut,
            category: _category!,
            colors: _colors,
            tags: _tags,
          ),
        );
      } else {
        saved = await svc.create(ClothDraft(
          name: _name.text.trim(),
          brand: (_brandField?.text ?? '').trim(),
          cut: cut,
          category: _category!,
          colors: List.of(_colors),
          tags: List.of(_tags),
          images: _newImages.map((p) => File(p)).toList(),
        ));
      }
      // Persist the rating too — update() above ignores score, so do it here.
      if (_score != _scoreBeforeEdit) {
        try {
          await svc.setScore(saved.id, _score);
          saved; // (kept for clarity; unused)
        } catch (_) {}
      }
      if (!mounted) return;
      if (widget.isEdit) {
        // Edit: just pop back to the detail screen, which will refetch.
        _toastKey('form.clothUpdated');
        Navigator.pop(context, true);
      } else {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => ClothDetailScreen(clothId: saved.id),
          ),
        );
      }
    } catch (e) {
      _toastKey('form.saveFailed', e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Translated toast by key (+ optional error). Keeps `context` out of the
  /// async call sites, so no use-after-await lint.
  void _toastKey(String key, [Object? err]) {
    if (!mounted) return;
    final msg = tr(context, key);
    _toast(err == null ? msg : '$msg: $err');
  }

  /// Called on every keystroke in the name field: recognise a brand and a
  /// garment type in what the user typed and pre-fill those fields.
  void _onNameChanged(String name) {
    _maybeAutofillBrand(name);
    _maybeAutofillCategory(name);
  }

  /// Recognise a brand in the typed name and pre-fill the Brand field — but only
  /// when it's empty, so the user's own entry is never overwritten (they can
  /// still change or clear it).
  void _maybeAutofillBrand(String name) {
    final field = _brandField;
    if (field == null || field.text.trim().isNotEmpty) return;
    final brand = detectBrandInName(name, extra: _brandSuggestions);
    if (brand != null) field.text = brand.toUpperCase();
  }

  /// Recognise a garment type in the typed name (e.g. "t shirt" → T-shirt) and
  /// pre-fill the Type dropdown — only when it's still unset, so a choice the
  /// user already made is never overwritten (they can still change it).
  void _maybeAutofillCategory(String name) {
    if (_category != null) return;
    final cat = detectCategoryInName(name);
    if (cat != null) setState(() => _category = cat);
  }

  Future<void> _replaceImage(int index) async {
    final path = await _pickFilePath();
    if (!mounted || path == null) return;   // the picker outlives this screen
    setState(() => _newImages[index] = path);
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.isEdit;

    return Scaffold(
      appBar: AppBar(title: Text(isEdit ? tr(context, 'form.editTitle') : tr(context, 'wardrobe.addClothes'))),
      // Tapping anywhere (or scrolling) drops focus, which dismisses the tag /
      // brand autocomplete overlay so it never gets stuck open.
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => FocusScope.of(context).unfocus(),
        child: SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr(context, 'form.name'),
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 8),
            TextField(
              controller: _name,
              onChanged: _onNameChanged,
              decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  hintText: tr(context, 'form.nameHint')),
            ),
            const SizedBox(height: 24),

            Text(tr(context, 'form.pictures'),
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 4),
            Text(_picturesHint(isEdit),
                style: const TextStyle(color: Colors.grey, fontSize: 12)),
            const SizedBox(height: 8),
            if (isEdit)
              // Edit mode: live, server-backed tiles (tap = replace, ✕ = delete).
              ...[
              if (_existingImages.isEmpty)
                Text(tr(context, 'form.noPictures'),
                    style: const TextStyle(color: Colors.grey)),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (var i = 0; i < _existingImages.length; i++)
                    _EditablePhotoTile(
                      label: _multiAngle
                          ? '${tr(context, 'form.photo')} ${i + 1}'
                          : _existingImages[i].role == 'front'
                              ? tr(context, 'form.front')
                              : _existingImages[i].role == 'back'
                                  ? tr(context, 'form.back')
                                  : '${tr(context, 'form.photo')} ${i + 1}',
                      // A small strip of previews, not the stored files.
                      imageUrl: _existingImages[i].thumbnailUrl == null
                          ? null
                          : imageUrl(_existingImages[i].thumbnailUrl!),
                      method: _existingImages[i].enhanceMethod,
                      bgAccepted: _existingImages[i].bgAccepted,
                      busy: _imgBusy,
                      onReplace: () =>
                          _replaceExistingImage(_existingImages[i].id),
                      onImprove: () =>
                          _enhanceExisting(_existingImages[i].id),
                      onCropRotate: () => _editPhoto(_existingImages[i]),
                      // Front/back are required — replace-only, no delete. Only
                      // extra photos can be removed.
                      onDelete: _existingImages[i].role == 'extra'
                          ? () => _deleteExistingImage(_existingImages[i].id)
                          : null,
                    ),
                ],
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _imgBusy ? null : _addImageNow,
                icon: _imgBusy
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.add_a_photo),
                label: Text(tr(context, 'form.addAnotherPicture')),
              ),
            ]
            else
              // Add mode: pick files now; they're uploaded when you save.
              ...[
              if (_newImages.isEmpty)
                Text(tr(context, 'form.noPicturesSelected'),
                    style: const TextStyle(color: Colors.grey)),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (var i = 0; i < _newImages.length; i++)
                    ImageSlot(
                      label: _multiAngle
                          ? '${tr(context, 'form.photo')} ${i + 1}${i == 0 ? '*' : ''}'
                          : i == 0
                              ? '${tr(context, 'form.front')}*'
                              : i == 1
                                  ? '${tr(context, 'form.back')}*'
                                  : '${tr(context, 'form.photo')} ${i + 1}',
                      path: _newImages[i],
                      required: i < (_multiAngle ? 1 : 2),
                      onTap: () => _replaceImage(i),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _pickImage,
                icon: const Icon(Icons.add_a_photo),
                label: Text(_multiAngle
                    ? (_newImages.isEmpty
                        ? tr(context, 'form.pickPicture')
                        : tr(context, 'form.addAngleOptional'))
                    : _newImages.isEmpty
                        ? tr(context, 'form.pickFront')
                        : _newImages.length == 1
                            ? tr(context, 'form.pickBack')
                            : tr(context, 'form.addPictureOptional')),
              ),
            ],
            const Divider(height: 40),

            Text(tr(context, 'filter.brand'),
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 8),
            Autocomplete<String>(
              optionsBuilder: (v) {
                if (v.text.isEmpty) {
                  // Pre-fill on edit so the field shows the current brand.
                  return _brandSuggestions;
                }
                return _brandSuggestions
                    .where((b) => b.toLowerCase().contains(v.text.toLowerCase()));
              },
              initialValue: widget.isEdit
                  ? TextEditingValue(text: widget.initial!.brand)
                  : null,
              onSelected: (s) {},
              fieldViewBuilder: (c, ctrl, fn, onSub) {
                _brandField = ctrl;
                return TextField(
                  controller: ctrl,
                  focusNode: fn,
                  // Brands are stored uppercase — force it as the user types.
                  textCapitalization: TextCapitalization.characters,
                  inputFormatters: [_UpperCaseFormatter()],
                  decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      labelText: tr(context, 'filter.brand'),
                      hintText: tr(context, 'form.brandHint')),
                );
              },
            ),
            const SizedBox(height: 24),

            Text(tr(context, 'form.category'),
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: _category,
              isExpanded: true,
              decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  hintText: tr(context, 'form.categoryHint')),
              items: kCategoryOptions
                  .map((c) => DropdownMenuItem(
                        value: c,
                        child: Text(categoryName(context, c)),
                      ))
                  .toList(),
              onChanged: (v) => setState(() => _category = v),
            ),
            // "Cut" only applies to garments — hidden for shoes, bags, hats, etc.
            if (categoryHasCut(_category)) ...[
              const SizedBox(height: 24),
              Text(tr(context, 'filter.cut'),
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                segments: kCutOptions
                    .map((c) => ButtonSegment(value: c, label: Text(cutLabel(context, c))))
                    .toList(),
                selected: {_cut},
                onSelectionChanged: (s) => setState(() => _cut = s.first),
              ),
            ],
            const Divider(height: 40),

            Text(tr(context, 'form.rating'),
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 4),
            Text(tr(context, 'form.ratingHint'),
                style: const TextStyle(color: Colors.grey, fontSize: 12)),
            const SizedBox(height: 8),
            Row(children: [
              for (int i = 1; i <= 5; i++)
                IconButton(
                  icon: Icon(
                    i <= _score ? Icons.star : Icons.star_border,
                    color: i <= _score ? Colors.amber : Colors.white38,
                    size: 32,
                  ),
                  onPressed: () => setState(() => _score = _score == i ? 0 : i),
                ),
              const SizedBox(width: 8),
              if (_score == 0)
                Text(tr(context, 'form.notRated'),
                    style: const TextStyle(color: Colors.grey)),
            ]),
            const Divider(height: 40),

            Text(tr(context, 'form.colors'),
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 8),
            ..._colors.asMap().entries.map((e) => ColorRow(
                  value: e.value,
                  onChanged: (c) => setState(() => _colors[e.key] = c),
                  onDelete: () => setState(() => _colors.removeAt(e.key)),
                )),
            Row(children: [
              OutlinedButton.icon(
                onPressed: _addColor,
                icon: const Icon(Icons.color_lens_outlined),
                label: Text(tr(context, 'form.addColor')),
              ),
              // Auto-detect from the cut-out — only once the cloth exists with a
              // background-removed photo. Suggestions merge in; edit freely after.
              if (widget.isEdit) ...[
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _detectingColors ? null : _detectColors,
                  icon: _detectingColors
                      ? const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.auto_awesome),
                  label: Text(tr(context, 'form.detectColors')),
                ),
              ],
            ]),
            const Divider(height: 40),

            Text(tr(context, 'form.customTags'),
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 4),
            Text(tr(context, 'form.tagsHint'),
                style: const TextStyle(color: Colors.grey, fontSize: 12)),
            const SizedBox(height: 8),
            Autocomplete<String>(
              optionsBuilder: (v) {
                if (v.text.isEmpty) return _tagSuggestions;
                return _tagSuggestions
                    .where((t) => t.toLowerCase().contains(v.text.toLowerCase()));
              },
              onSelected: (s) {
                _addTag(s);
                _tagField?.clear();
              },
              fieldViewBuilder: (c, ctrl, fn, onSub) {
                _tagField = ctrl;
                return TextField(
                  controller: ctrl,
                  focusNode: fn,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    labelText: tr(context, 'form.addTag'),
                    hintText: tr(context, 'form.tagFieldHint'),
                    prefixIcon: const Icon(Icons.tag, size: 20),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.add),
                      tooltip: tr(context, 'form.add'),
                      onPressed: () {
                        _addTag(ctrl.text);
                        ctrl.clear();
                      },
                    ),
                  ),
                  // Commit as soon as a comma is typed → an instant chip.
                  onChanged: (v) {
                    if (v.endsWith(',')) {
                      _addTag(v);
                      ctrl.clear();
                    }
                  },
                  onSubmitted: (v) {
                    _addTag(v);
                    ctrl.clear();
                    fn.requestFocus();
                  },
                );
              },
            ),
            const SizedBox(height: 12),
            if (_tags.isEmpty)
              Text(tr(context, 'form.noTags'), style: const TextStyle(color: Colors.grey))
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _tags
                    .map((t) => Chip(
                          avatar: const Icon(Icons.tag, size: 16),
                          label: Text(t),
                          onDeleted: () => setState(() => _tags.remove(t)),
                        ))
                    .toList(),
              ),
            const Divider(height: 40),

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
                    : Text(isEdit ? tr(context, 'form.saveChanges') : tr(context, 'form.save'),
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }
}

/// Editable thumbnail used in edit mode: tap the image to replace it, tap the
/// ✕ badge to delete it. Both actions hit the server and refresh live.
class _EditablePhotoTile extends StatelessWidget {
  const _EditablePhotoTile({
    required this.label,
    required this.imageUrl,
    required this.method,
    required this.bgAccepted,
    required this.busy,
    required this.onReplace,
    required this.onImprove,
    required this.onCropRotate,
    required this.onDelete,
  });
  final String label;
  final String? imageUrl;
  final String method; // 'none' | 'auto' | 'ai'
  final String bgAccepted; // 'pending' | 'accepted' | 'rejected'
  final bool busy;
  final VoidCallback onReplace;
  final VoidCallback onImprove;
  final VoidCallback onCropRotate;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 110,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Stack(children: [
          GestureDetector(
            onTap: busy ? null : onReplace,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Container(
                width: 110,
                height: 110,
                color: Colors.blueGrey.shade900,
                child: imageUrl == null
                    ? const Icon(Icons.image, color: Colors.white38)
                    : AppImage(url: imageUrl!, fit: BoxFit.contain,
                        cacheKey: imageUrl, memWidth: 220),
              ),
            ),
          ),
          // Crop & rotate.
          Positioned(
            bottom: 4,
            right: 4,
            child: GestureDetector(
              onTap: busy ? null : onCropRotate,
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: const BoxDecoration(
                    color: Colors.black54, shape: BoxShape.circle),
                child: const Icon(Icons.crop_rotate, size: 14, color: Colors.white),
              ),
            ),
          ),
          // "Improve" (✨) — enhance this existing photo.
          Positioned(
            bottom: 4,
            left: 4,
            child: GestureDetector(
              onTap: busy ? null : onImprove,
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: const BoxDecoration(
                    color: Colors.black54, shape: BoxShape.circle),
                child: const Icon(Icons.auto_fix_high,
                    size: 14, color: Colors.tealAccent),
              ),
            ),
          ),
          if (onDelete != null)
            Positioned(
              top: 2,
              left: 2,
              child: GestureDetector(
                onTap: busy ? null : onDelete,
                child: Container(
                  padding: const EdgeInsets.all(2),
                  decoration: const BoxDecoration(
                      color: Colors.redAccent, shape: BoxShape.circle),
                  child: const Icon(Icons.close, size: 14, color: Colors.white),
                ),
              ),
            ),
        ]),
        const SizedBox(height: 4),
        Row(children: [
          Expanded(
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12))),
        ]),
        // Cut-out / Original / Review + how the photo was processed.
        Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Wrap(spacing: 4, runSpacing: 4, children: [
            BgStatusBadge(status: bgAccepted),
            if (method != 'none') EnhanceMethodBadge(method: method),
          ]),
        ),
      ]),
    );
  }
}

/// Legacy alias kept so any existing call-site that referenced the old name
/// still works (e.g. the Collection grid's "Add cloth" button).
typedef AddClothScreen = ClothFormScreen;

/// Uppercases text as it's typed — used for the brand field so brands are
/// stored/displayed consistently (nike → NIKE).
class _UpperCaseFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    return newValue.copyWith(text: newValue.text.toUpperCase());
  }
}