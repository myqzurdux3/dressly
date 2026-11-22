import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../config/api_config.dart';
import '../../design/ds.dart';
import '../../l10n/app_text.dart';
import '../../models/cloth.dart';
import '../../state/providers.dart';
import '../../widgets/app_image.dart';

/// Manual photo editor: rotate in 90° steps (instant, client-side) and drag a
/// crop rectangle. On "Done" the rotation + crop are applied server-side in a
/// single call to the original AND the cut-out (so background removal stays
/// aligned). "Redo background" additionally re-runs removal on the result.
/// Pops with the updated [Cloth] if anything changed, or null if cancelled.
class PhotoEditScreen extends ConsumerStatefulWidget {
  const PhotoEditScreen({
    super.key,
    required this.clothId,
    required this.image,
    this.imageProvider = appImageProvider,
  });

  final int clothId;
  final ClothImage image;

  /// Builds the provider that both measures and displays the photo. Tests
  /// swap it, because the app's disk cache needs a platform to run.
  @visibleForTesting
  final ImageProvider Function(String url) imageProvider;

  @override
  ConsumerState<PhotoEditScreen> createState() => _PhotoEditScreenState();
}

class _PhotoEditScreenState extends ConsumerState<PhotoEditScreen> {
  late String _url;
  Cloth? _result; // latest server-side state, returned to the caller on Done
  Size? _imgSize; // natural (unrotated) size
  int _turns = 0; // clockwise 90° steps applied on the client
  Rect _crop = const Rect.fromLTRB(0, 0, 1, 1); // normalized, rotated frame
  bool _busy = false;
  late String _tolerance = widget.image.bgTolerance;
  bool _popped = false; // guards against a double-pop (back + button race)
  bool _loadError = false; // the image could not be loaded; offer a retry

  static const double _minSize = 0.12;

  @override
  void initState() {
    super.initState();
    _url = imageUrl(widget.image.displayUrl ?? widget.image.originalUrl);
    _loadSize();
  }

  /// Resolves the natural pixel size of [_url] so the crop frame matches it.
  ///
  /// Goes through the app's disk cache (the same provider the crop view
  /// displays), so the photo is downloaded once rather than twice. The
  /// provider is not resized, so the reported size is the natural one.
  void _loadSize() {
    if (_loadError) {
      // Drop the failed entry so the retry really goes back to the network.
      widget.imageProvider(_url).evict();
      setState(() => _loadError = false);
    }
    final stream = widget.imageProvider(_url).resolve(ImageConfiguration.empty);
    late final ImageStreamListener l;
    l = ImageStreamListener((info, _) {
      if (mounted) {
        setState(
          () => _imgSize = Size(
            info.image.width.toDouble(),
            info.image.height.toDouble(),
          ),
        );
      }
      stream.removeListener(l);
    }, onError: (_, __) {
      stream.removeListener(l);
      // Without this the editor showed its spinner forever.
      if (mounted) setState(() => _loadError = true);
    });
    stream.addListener(l);
  }

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  /// Pops at most once, even if the back button and a button race.
  void _safePop(Cloth? result) {
    if (_popped || !mounted) return;
    _popped = true;
    Navigator.pop(context, result);
  }

  ClothImage? _imageById(Cloth c, int id) {
    for (final im in c.images) {
      if (im.id == id) return im;
    }
    return null;
  }

  static const _tolKeys = {
    'low': 'review.soft',
    'medium': 'review.balanced',
    'high': 'review.strong',
  };

  bool get _cropIsFull =>
      _crop.left <= 0.001 &&
      _crop.top <= 0.001 &&
      _crop.right >= 0.999 &&
      _crop.bottom >= 0.999;

  void _rotate(int deltaTurns) => setState(() {
    _turns = (_turns + deltaTurns) % 4;
    _crop = const Rect.fromLTRB(0, 0, 1, 1); // frame changed → reset crop
  });

  List<double>? get _cropArg =>
      _cropIsFull ? null : [_crop.left, _crop.top, _crop.right, _crop.bottom];

  /// Finish editing: apply any pending rotate/crop server-side, then close.
  Future<void> _done() async {
    if (_busy) return;
    final rotate = (_turns * 90) % 360;
    final hasTransform = rotate != 0 || !_cropIsFull;
    if (!hasTransform) {
      _safePop(_result); // nothing new to apply — return whatever we last got
      return;
    }
    setState(() => _busy = true);
    try {
      final svc = ref.read(clothesServiceProvider);
      final result = await svc.transformImage(
        widget.clothId,
        widget.image.id,
        rotate: rotate,
        crop: _cropArg,
      );
      if (!mounted) return;
      _safePop(result);
    } catch (e) {
      _toast(tr(context, 'photo.applyFailed'));
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Re-run background removal at [tolerance], applying any pending crop/rotate
  /// first so the cut-out matches what's on screen. Stays in the editor and
  /// refreshes the preview in place — so it can never race the screen's pop.
  Future<void> _redoBg(String tolerance) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final svc = ref.read(clothesServiceProvider);
      final rotate = (_turns * 90) % 360;
      if (rotate != 0 || !_cropIsFull) {
        await svc.transformImage(
          widget.clothId,
          widget.image.id,
          rotate: rotate,
          crop: _cropArg,
        );
      }
      final result = await svc.redoBackground(
        widget.clothId,
        widget.image.id,
        tolerance: tolerance,
      );
      if (!mounted) return;
      final img = _imageById(result, widget.image.id);
      setState(() {
        _result = result;
        _turns = 0; // the transform is now baked into the server image
        _crop = const Rect.fromLTRB(0, 0, 1, 1);
        _imgSize = null;
        _tolerance = tolerance;
        if (img != null) _url = imageUrl(img.displayUrl ?? img.originalUrl);
      });
      _loadSize();
      final tolLabel = _tolKeys[tolerance] != null
          ? tr(context, _tolKeys[tolerance]!)
          : tolerance;
      _toast(tr(context, 'photo.cutoutUpdated', {'level': tolLabel}));
    } catch (e) {
      _toast(tr(context, 'photo.bgFailed'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final c = ds.colors;
    final rotated = _turns.isOdd;
    return PopScope(
      // Block back while an operation is in flight, so a back-press can never
      // race the redo/transform and pop a locked navigator (app crash).
      canPop: !_busy,
      child: Scaffold(
        backgroundColor: c.bg,
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: EdgeInsets.all(ds.space.s),
                child: Row(
                  children: [
                    DsButton.icon(
                      icon: Icons.close,
                      semanticLabel: MaterialLocalizations.of(
                        context,
                      ).closeButtonTooltip,
                      onPressed: _busy
                          ? null
                          : () => Navigator.maybePop(context),
                    ),
                    SizedBox(width: ds.space.s),
                    Expanded(
                      child: Text(
                        tr(context, 'photo.editPhoto').toUpperCase(),
                        style: ds.typo.mono,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    DsButton(
                      label: tr(context, 'photo.done'),
                      icon: Icons.check,
                      loading: _busy,
                      onPressed: _busy ? null : _done,
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Center(
                  child: _imgSize == null
                      ? (_loadError
                            ? DsError(
                                message: tr(context, 'common.loadFailed'),
                                retryLabel: tr(context, 'common.retry'),
                                onRetry: _loadSize,
                              )
                            : CircularProgressIndicator(color: c.accent))
                      : Padding(
                          padding: EdgeInsets.all(ds.space.l),
                          child: AspectRatio(
                            // Displayed (rotated) aspect ratio.
                            aspectRatio: rotated
                                ? _imgSize!.height / _imgSize!.width
                                : _imgSize!.width / _imgSize!.height,
                            child: LayoutBuilder(
                              builder: (ctx, cons) {
                                final w = cons.maxWidth, h = cons.maxHeight;
                                final pr = Rect.fromLTRB(
                                  _crop.left * w,
                                  _crop.top * h,
                                  _crop.right * w,
                                  _crop.bottom * h,
                                );
                                return Stack(
                                  children: [
                                    Positioned.fill(
                                      child: RotatedBox(
                                        quarterTurns: _turns,
                                        child: Image(
                                          image: widget.imageProvider(_url),
                                          key: ValueKey(_url),
                                          fit: BoxFit.fill,
                                        ),
                                      ),
                                    ),
                                    Positioned.fill(
                                      child: IgnorePointer(
                                        child: CustomPaint(
                                          painter: _MaskPainter(
                                            pr,
                                            scrim: c.bg.withValues(alpha: 0.6),
                                            stroke: c.accent,
                                          ),
                                        ),
                                      ),
                                    ),
                                    Positioned.fromRect(
                                      rect: pr,
                                      child: GestureDetector(
                                        behavior: HitTestBehavior.translucent,
                                        onPanUpdate: (d) =>
                                            _move(d.delta, w, h),
                                      ),
                                    ),
                                    ..._handles(context, pr, w, h),
                                  ],
                                );
                              },
                            ),
                          ),
                        ),
                ),
              ),
              if (_busy)
                LinearProgressIndicator(
                  color: c.accent,
                  backgroundColor: c.surface,
                ),
              Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: ds.space.gutter,
                  vertical: ds.space.s,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _ToolButton(
                          icon: Icons.rotate_left,
                          label: tr(context, 'photo.rotateLeft'),
                          onTap: _busy ? null : () => _rotate(3),
                        ),
                        _ToolButton(
                          icon: Icons.rotate_right,
                          label: tr(context, 'photo.rotateRight'),
                          onTap: _busy ? null : () => _rotate(1),
                        ),
                        _ToolButton(
                          icon: Icons.crop_free,
                          label: tr(context, 'photo.resetCrop'),
                          onTap: _busy
                              ? null
                              : () => setState(
                                  () => _crop = const Rect.fromLTRB(0, 0, 1, 1),
                                ),
                        ),
                      ],
                    ),
                    DsSectionTitle(
                      tr(context, 'photo.redoAt'),
                      hint: tr(context, 'detail.strengthHint'),
                    ),
                    // Picking a strength re-runs the cut-out right away (the
                    // pending crop and rotation are applied first).
                    DsSegment<String>(
                      options: [
                        ('low', tr(context, 'detail.soft')),
                        ('medium', tr(context, 'detail.balanced')),
                        ('high', tr(context, 'detail.strong')),
                      ],
                      value: _tolerance,
                      onChanged: (t) {
                        if (!_busy) _redoBg(t);
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _move(Offset delta, double w, double h) {
    final dx = delta.dx / w, dy = delta.dy / h;
    var l = _crop.left + dx, t = _crop.top + dy;
    var r = _crop.right + dx, b = _crop.bottom + dy;
    if (l < 0) {
      r -= l;
      l = 0;
    }
    if (t < 0) {
      b -= t;
      t = 0;
    }
    if (r > 1) {
      l -= (r - 1);
      r = 1;
    }
    if (b > 1) {
      t -= (b - 1);
      b = 1;
    }
    setState(
      () => _crop = Rect.fromLTRB(
        l.clamp(0, 1),
        t.clamp(0, 1),
        r.clamp(0, 1),
        b.clamp(0, 1),
      ),
    );
  }

  List<Widget> _handles(BuildContext context, Rect pr, double w, double h) {
    final c = context.ds.colors;
    // Big invisible hit area (56px) around a clearly-visible dot, so corners
    // are easy to grab with a fingertip on a phone.
    const hit = 56.0;
    Widget handle(Offset pos, void Function(Offset) onDrag) => Positioned(
      left: pos.dx - hit / 2,
      top: pos.dy - hit / 2,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onPanUpdate: (d) => onDrag(d.delta),
        child: Container(
          width: hit,
          height: hit,
          alignment: Alignment.center,
          child: Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: c.text,
              shape: BoxShape.circle,
              border: Border.all(color: c.accent, width: 3),
            ),
          ),
        ),
      ),
    );

    void update({double? l, double? t, double? r, double? b}) {
      var nl = l ?? _crop.left, nt = t ?? _crop.top;
      var nr = r ?? _crop.right, nb = b ?? _crop.bottom;
      nl = nl.clamp(0.0, nr - _minSize);
      nt = nt.clamp(0.0, nb - _minSize);
      nr = nr.clamp(nl + _minSize, 1.0);
      nb = nb.clamp(nt + _minSize, 1.0);
      setState(() => _crop = Rect.fromLTRB(nl, nt, nr, nb));
    }

    return [
      handle(
        pr.topLeft,
        (d) => update(l: _crop.left + d.dx / w, t: _crop.top + d.dy / h),
      ),
      handle(
        pr.topRight,
        (d) => update(r: _crop.right + d.dx / w, t: _crop.top + d.dy / h),
      ),
      handle(
        pr.bottomLeft,
        (d) => update(l: _crop.left + d.dx / w, b: _crop.bottom + d.dy / h),
      ),
      handle(
        pr.bottomRight,
        (d) => update(r: _crop.right + d.dx / w, b: _crop.bottom + d.dy / h),
      ),
    ];
  }
}

class _MaskPainter extends CustomPainter {
  _MaskPainter(this.hole, {required this.scrim, required this.stroke});

  final Rect hole;
  final Color scrim;
  final Color stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final full = Path()..addRect(Offset.zero & size);
    final holePath = Path()..addRect(hole);
    final mask = Path.combine(PathOperation.difference, full, holePath);
    canvas.drawPath(mask, Paint()..color = scrim);
    canvas.drawRect(
      hole,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_MaskPainter old) =>
      old.hole != hole || old.scrim != scrim || old.stroke != stroke;
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({required this.icon, required this.label, this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final c = ds.colors;
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(ds.shape.small),
        child: Padding(
          padding: EdgeInsets.all(ds.space.xs),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: c.surface,
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: onTap == null ? c.textMuted : c.text),
              ),
              SizedBox(height: ds.space.xs),
              Text(
                label.toUpperCase(),
                style: ds.typo.monoSmall.copyWith(color: c.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
