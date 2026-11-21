import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../design/ds.dart';
import '../../l10n/app_text.dart';
import '../../models/cloth.dart';
import '../../services/clothes_service.dart';
import '../../state/providers.dart';
import 'photo_review.dart';
import 'cloth_detail_screen.dart';
import 'detail/detail_image_panel.dart' show roleLabel;
import 'form/color_editor.dart';
import 'form/form_photos.dart';
import 'photo_edit_screen.dart';

/// Reused for both adding a new cloth and editing an existing one. When
/// [initial] is non-null the form is pre-populated and saving PUTs instead of
/// POSTing — switching an item between add and edit mode in one screen keeps
/// the field layout in lockstep.
class ClothFormScreen extends ConsumerStatefulWidget {
  const ClothFormScreen({super.key, this.initial});

  final Cloth? initial;

  bool get isEdit => initial != null;

  @override
  ConsumerState<ClothFormScreen> createState() => _ClothFormScreenState();
}

class _ClothFormScreenState extends ConsumerState<ClothFormScreen> {
  ClothesService get _svc => ref.read(clothesServiceProvider);

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
    final svc = _svc;
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
    if (!mounted || path == null) return; // the picker outlives this screen
    setState(() => _newImages.add(path));
    _autoDetectColors();
  }

  /// Once the photos are in, suggest the colours — unless the user already
  /// set some by hand, which a detection must never overwrite.
  void _autoDetectColors() {
    if (widget.isEdit || _colorsTouched) return;
    if (_newImages.length < (_multiAngle ? 1 : 2)) return;
    _detectColors(auto: true);
  }

  // ---- Edit-mode live image management (server-backed) ----

  /// Lets the user take a photo with the camera or pick a file, then returns
  /// its local path (or null if cancelled).
  Future<String?> _pickFilePath() async {
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
                title: Text(tr(context, key), style: ctx.ds.typo.bodyStrong),
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
        builder: (_) =>
            PhotoEditScreen(clothId: widget.initial!.id, image: img),
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
    final svc = _svc;
    final path = await _pickFilePath();
    if (!mounted || path == null) return; // the picker outlives this screen
    setState(() => _imgBusy = true);
    try {
      final updated = await svc.replaceImage(
        widget.initial!.id,
        imageId,
        File(path),
      );
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
    final svc = _svc;
    final path = await _pickFilePath();
    if (!mounted || path == null) return; // the picker outlives this screen
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
        final c = await svc.redoBackground(
          widget.initial!.id,
          imageId,
          tolerance: level,
        );
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
    final svc = _svc;
    await _decideCrop(svc, imageId);
    if (!mounted) return;
    final mode = await showEnhanceChoice(context);
    if (mode == null) return;
    await _runEnhance(svc, imageId, mode);
  }

  /// Enhance an existing photo on demand (from the tile's ✨ button).
  Future<void> _enhanceExisting(int imageId) async {
    if (_imgBusy) return;
    final svc = _svc;
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
        final choice = await showEnhancePreview(
          context,
          currentUrl: img.displayPreviewUrl ?? img.originalPreview,
          enhancedUrl: img.enhancedPreview,
          method: mode,
          nextTier: mode == 'ai' ? img.enhanceNextTier : null,
        );
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
      final updated = await _svc.deleteImage(widget.initial!.id, imageId);
      if (!mounted) return;
      setState(() => _existingImages = [...updated.images]);
      _toastKey('form.pictureRemoved');
    } catch (e) {
      _toastKey('form.removeFailed', e);
    } finally {
      if (mounted) setState(() => _imgBusy = false);
    }
  }

  void _addColor() => setState(() {
    _colorsTouched = true;
    _colors.add(ClothColor(color: 'Black', dominance: 'part'));
  });

  bool _detectingColors = false;

  /// The user changed the colour list by hand: automatic suggestions stop
  /// replacing it.
  bool _colorsTouched = false;
  bool _autoDetecting = false;

  /// Ask the server to detect the garment's colors — from its cut-out when it
  /// exists, else from the photos just picked — and merge the suggestions in
  /// (skipping ones already listed). The user edits freely. [auto] is the
  /// suggestion made once the photos are in: it replaces the list, which the
  /// user has not touched yet, and stays quiet when it finds nothing.
  Future<void> _detectColors({bool auto = false}) async {
    if (_detectingColors || _autoDetecting) return;
    // The automatic pass runs in the background: no spinner on the button,
    // which the user did not press.
    if (auto) {
      _autoDetecting = true;
    } else {
      setState(() => _detectingColors = true);
    }
    try {
      final detected = widget.isEdit
          ? await _svc.detectColors(widget.initial!.id)
          : await _svc.detectPhotoColors(_newImages);
      if (!mounted) return;
      if (auto) {
        if (detected.isNotEmpty && !_colorsTouched) {
          setState(
            () => _colors
              ..clear()
              ..addAll(detected),
          );
          _toastKey('form.colorsSuggested');
        }
        return;
      }
      if (detected.isEmpty) {
        _toastKey('form.noColors');
        return;
      }
      final existing = _colors.map((c) => c.color.toLowerCase()).toSet();
      final added = detected
          .where((d) => !existing.contains(d.color.toLowerCase()))
          .toList();
      setState(() => _colors.addAll(added));
      _toast(
        added.isEmpty
            ? tr(context, 'form.colorsAlready')
            : tr(context, 'form.colorsAdded'),
      );
    } catch (e) {
      if (!auto) _toastKey('form.detectFailed', e);
    } finally {
      _autoDetecting = false;
      if (mounted && !auto) setState(() => _detectingColors = false);
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
      return tr(
        context,
        isEdit ? 'form.picHintMultiEdit' : 'form.picHintMultiAdd',
      );
    }
    return tr(
      context,
      isEdit ? 'form.picHintGarmentEdit' : 'form.picHintGarmentAdd',
    );
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
      _toast(
        _multiAngle
            ? tr(context, 'form.minOnePicture')
            : tr(context, 'form.frontBackRequired'),
      );
      return;
    }
    // No cut for shoes / bags / accessories — send it empty so it's not stored.
    final cut = categoryHasCut(_category) ? _cut : '';
    setState(() => _saving = true);
    try {
      final svc = _svc;
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
        saved = await svc.create(
          ClothDraft(
            name: _name.text.trim(),
            brand: (_brandField?.text ?? '').trim(),
            cut: cut,
            category: _category!,
            colors: List.of(_colors),
            tags: List.of(_tags),
            images: _newImages.map((p) => File(p)).toList(),
          ),
        );
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
    if (!mounted || path == null) return; // the picker outlives this screen
    setState(() => _newImages[index] = path);
    _autoDetectColors();
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final c = ds.colors;
    final isEdit = widget.isEdit;
    final gap = SizedBox(height: ds.space.s);

    return Scaffold(
      backgroundColor: c.bg,
      // Tapping anywhere (or scrolling) drops focus, which dismisses the tag /
      // brand autocomplete overlay so it never gets stuck open.
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => FocusScope.of(context).unfocus(),
        child: SafeArea(
          bottom: false,
          child: SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: EdgeInsets.only(bottom: ds.space.xxl),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DsHeader(
                  line1: tr(
                    context,
                    isEdit ? 'form.title1Edit' : 'form.title1New',
                  ),
                  line2: tr(context, 'form.title2'),
                  trailing: DsButton.icon(
                    icon: Icons.close,
                    semanticLabel: MaterialLocalizations.of(
                      context,
                    ).closeButtonTooltip,
                    onPressed: () => Navigator.maybePop(context),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: ds.space.gutter),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      DsSectionTitle(tr(context, 'form.name')),
                      TextField(
                        controller: _name,
                        onChanged: _onNameChanged,
                        style: ds.typo.body,
                        decoration: InputDecoration(
                          hintText: tr(context, 'form.nameHint'),
                        ),
                      ),
                      DsSectionTitle(
                        tr(context, 'form.pictures'),
                        hint: _picturesHint(isEdit),
                      ),
                      Wrap(
                        spacing: ds.space.s,
                        runSpacing: ds.space.s,
                        children: isEdit
                            ? _existingPhotoTiles(context)
                            : _newPhotoTiles(context),
                      ),
                      DsSectionTitle(tr(context, 'filter.brand')),
                      Autocomplete<String>(
                        optionsBuilder: (v) {
                          // Empty: every brand, so the list is browsable.
                          if (v.text.isEmpty) return _brandSuggestions;
                          return _brandSuggestions.where(
                            (b) =>
                                b.toLowerCase().contains(v.text.toLowerCase()),
                          );
                        },
                        initialValue: isEdit
                            ? TextEditingValue(text: widget.initial!.brand)
                            : null,
                        onSelected: (_) {},
                        fieldViewBuilder: (_, ctrl, fn, _) {
                          _brandField = ctrl;
                          return TextField(
                            controller: ctrl,
                            focusNode: fn,
                            style: ds.typo.body,
                            // Brands are stored uppercase — forced as typed.
                            textCapitalization: TextCapitalization.characters,
                            inputFormatters: [_UpperCaseFormatter()],
                            decoration: InputDecoration(
                              hintText: tr(context, 'form.brandHint'),
                            ),
                          );
                        },
                      ),
                      DsSectionTitle(tr(context, 'form.category')),
                    ],
                  ),
                ),
                Padding(
                  padding: EdgeInsets.only(left: ds.space.gutter),
                  child: DsSegment<String?>(
                    options: [
                      for (final cat in kCategoryOptions)
                        (cat, categoryName(context, cat)),
                    ],
                    value: _category,
                    onChanged: (v) => setState(() => _category = v),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: ds.space.gutter),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Cut only applies to garments, not shoes, bags, hats.
                      if (categoryHasCut(_category)) ...[
                        DsSectionTitle(tr(context, 'filter.cut')),
                        DsSegment<String>(
                          options: [
                            for (final cut in kCutOptions)
                              (cut, cutLabel(context, cut)),
                          ],
                          value: _cut,
                          onChanged: (v) => setState(() => _cut = v),
                        ),
                      ],
                      DsSectionTitle(
                        tr(context, 'form.rating'),
                        hint: tr(context, 'form.ratingHint'),
                      ),
                      DsRating(
                        score: _score,
                        onChanged: (v) => setState(() => _score = v),
                      ),
                      DsSectionTitle(tr(context, 'form.colors')),
                      for (var i = 0; i < _colors.length; i++)
                        ColorEditorRow(
                          key: ObjectKey(_colors[i]),
                          value: _colors[i],
                          onChanged: (v) => setState(() {
                            _colorsTouched = true;
                            _colors[i] = v;
                          }),
                          onDelete: () => setState(() {
                            _colorsTouched = true;
                            _colors.removeAt(i);
                          }),
                        ),
                      Wrap(
                        spacing: ds.space.s,
                        runSpacing: ds.space.s,
                        children: [
                          DsButton(
                            label: tr(context, 'form.addColor'),
                            icon: Icons.add,
                            kind: DsButtonKind.secondary,
                            onPressed: _addColor,
                          ),
                          // From the cut-out once the garment exists, else
                          // from the photos just picked.
                          if (isEdit || _newImages.isNotEmpty)
                            DsButton(
                              label: tr(context, 'form.detectColors'),
                              icon: Icons.auto_awesome,
                              kind: DsButtonKind.secondary,
                              loading: _detectingColors,
                              onPressed: _detectingColors
                                  ? null
                                  : _detectColors,
                            ),
                        ],
                      ),
                      DsSectionTitle(
                        tr(context, 'form.customTags'),
                        hint: tr(context, 'form.tagsHint'),
                      ),
                      Autocomplete<String>(
                        optionsBuilder: (v) {
                          if (v.text.isEmpty) return _tagSuggestions;
                          return _tagSuggestions.where(
                            (t) =>
                                t.toLowerCase().contains(v.text.toLowerCase()),
                          );
                        },
                        onSelected: (s) {
                          _addTag(s);
                          _tagField?.clear();
                        },
                        fieldViewBuilder: (_, ctrl, fn, _) {
                          _tagField = ctrl;
                          return TextField(
                            controller: ctrl,
                            focusNode: fn,
                            style: ds.typo.body,
                            textInputAction: TextInputAction.done,
                            decoration: InputDecoration(
                              hintText: tr(context, 'form.tagFieldHint'),
                              prefixIcon: Icon(Icons.tag, color: c.textMuted),
                              suffixIcon: IconButton(
                                icon: Icon(Icons.add, color: c.accent),
                                tooltip: tr(context, 'form.add'),
                                onPressed: () {
                                  _addTag(ctrl.text);
                                  ctrl.clear();
                                },
                              ),
                            ),
                            // A comma commits the tag at once.
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
                      gap,
                      if (_tags.isEmpty)
                        Text(
                          tr(context, 'form.noTags'),
                          style: ds.typo.label.copyWith(color: c.textMuted),
                        )
                      else
                        Wrap(
                          spacing: ds.space.xs,
                          runSpacing: ds.space.xs,
                          children: [
                            for (final t in _tags)
                              DsChip(
                                label: '#$t',
                                selected: false,
                                leading: Icon(
                                  Icons.close,
                                  size: 14,
                                  color: c.textMuted,
                                ),
                                onTap: () => setState(() => _tags.remove(t)),
                              ),
                          ],
                        ),
                      SizedBox(height: ds.space.xl),
                      DsButton(
                        label: tr(
                          context,
                          isEdit ? 'form.saveChanges' : 'form.save',
                        ),
                        expand: true,
                        loading: _saving,
                        onPressed: _saving ? null : _save,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _newLabel(int i) {
    if (_multiAngle) return '${tr(context, 'form.photo')} ${i + 1}';
    return switch (i) {
      0 => tr(context, 'form.front'),
      1 => tr(context, 'form.back'),
      _ => '${tr(context, 'form.photo')} ${i + 1}',
    };
  }

  /// Add mode: the photos picked so far (uploaded on save), then the tile
  /// that picks the next one, labelled with what is expected.
  List<Widget> _newPhotoTiles(BuildContext context) => [
    for (var i = 0; i < _newImages.length; i++)
      NewPhotoSlot(
        label: _newLabel(i),
        path: _newImages[i],
        onTap: () => _replaceImage(i),
      ),
    AddPhotoTile(
      label: _multiAngle
          ? tr(
              context,
              _newImages.isEmpty ? 'form.pickPicture' : 'form.addAngleOptional',
            )
          : tr(context, switch (_newImages.length) {
              0 => 'form.pickFront',
              1 => 'form.pickBack',
              _ => 'form.addPictureOptional',
            }),
      onTap: _pickImage,
    ),
  ];

  /// Edit mode: live, server-backed tiles, then the tile that adds one.
  List<Widget> _existingPhotoTiles(BuildContext context) => [
    for (var i = 0; i < _existingImages.length; i++)
      ExistingPhotoTile(
        key: ValueKey(_existingImages[i].id),
        label: _multiAngle || _existingImages[i].role == 'extra'
            ? '${tr(context, 'form.photo')} ${i + 1}'
            : roleLabel(context, _existingImages[i].role),
        image: _existingImages[i],
        busy: _imgBusy,
        onReplace: () => _replaceExistingImage(_existingImages[i].id),
        onImprove: () => _enhanceExisting(_existingImages[i].id),
        onCropRotate: () => _editPhoto(_existingImages[i]),
        // Front and back are required: replace-only. Extras can go.
        onDelete: _existingImages[i].role == 'extra'
            ? () => _deleteExistingImage(_existingImages[i].id)
            : null,
      ),
    AddPhotoTile(
      label: tr(context, 'form.addAnotherPicture'),
      busy: _imgBusy,
      onTap: _addImageNow,
    ),
  ];
}

/// Legacy alias kept so any existing call-site that referenced the old name
/// still works (e.g. the Collection grid's "Add cloth" button).
typedef AddClothScreen = ClothFormScreen;

/// Uppercases text as it's typed — used for the brand field so brands are
/// stored/displayed consistently (nike → NIKE).
class _UpperCaseFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    return newValue.copyWith(text: newValue.text.toUpperCase());
  }
}
