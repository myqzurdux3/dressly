import 'dart:io';

import 'package:flutter/material.dart';

import '../../../design/ds.dart';
import '../../../l10n/app_text.dart';
import '../../../models/cloth.dart';
import '../../../widgets/app_image.dart';
import '../detail/detail_image_panel.dart';

/// Size of every photo tile in the form.
const formPhotoWidth = 120.0;
const formPhotoHeight = 150.0;

class _TileFrame extends StatelessWidget {
  const _TileFrame({required this.child, this.border});

  final Widget child;
  final Color? border;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Container(
      width: formPhotoWidth,
      height: formPhotoHeight,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: ds.colors.surface,
        borderRadius: BorderRadius.circular(ds.shape.small),
        border: border == null ? null : Border.all(color: border!),
      ),
      child: child,
    );
  }
}

/// A photo picked on this device, not uploaded yet (add mode). Tap to pick
/// another one in its place.
class NewPhotoSlot extends StatelessWidget {
  const NewPhotoSlot({
    super.key,
    required this.label,
    required this.path,
    required this.onTap,
  });

  final String label;
  final String path;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final dpr = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0;
    return Semantics(
      button: true,
      label: '$label · ${tr(context, 'form.replacePhoto')}',
      child: GestureDetector(
        onTap: onTap,
        child: _TileFrame(
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Decoded at tile size: a 12 MP capture would otherwise sit in
              // memory in full for a 120 px box.
              Image.file(
                File(path),
                fit: BoxFit.cover,
                cacheWidth: (formPhotoWidth * dpr).round(),
              ),
              Positioned(
                top: ds.space.xs,
                left: ds.space.xs,
                child: DsBadge(text: label),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The empty tile that picks a photo. [label] says which one is expected
/// next (front, back, an optional angle…).
class AddPhotoTile extends StatelessWidget {
  const AddPhotoTile({
    super.key,
    required this.label,
    required this.onTap,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final c = ds.colors;
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: busy ? null : onTap,
        child: _TileFrame(
          border: c.hairline,
          child: Padding(
            padding: EdgeInsets.all(ds.space.s),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (busy)
                  SizedBox.square(
                    dimension: 28,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: c.accent,
                    ),
                  )
                else
                  Icon(Icons.add_a_photo_outlined, size: 32, color: c.accent),
                SizedBox(height: ds.space.s),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  style: ds.typo.label.copyWith(color: c.textMuted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A photo already on the server (edit mode): tap to replace it; small round
/// buttons to crop, enhance or (extra photos only) delete.
class ExistingPhotoTile extends StatelessWidget {
  const ExistingPhotoTile({
    super.key,
    required this.label,
    required this.image,
    required this.busy,
    required this.onReplace,
    required this.onImprove,
    required this.onCropRotate,
    this.onDelete,
  });

  final String label;
  final ClothImage image;
  final bool busy;
  final VoidCallback onReplace;
  final VoidCallback onImprove;
  final VoidCallback onCropRotate;

  /// Null for front and back: they are required, so replace-only.
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final url = image.thumbnailUrl;
    return SizedBox(
      width: formPhotoWidth,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Stack(
            children: [
              Semantics(
                button: true,
                label: '$label · ${tr(context, 'form.replacePhoto')}',
                child: GestureDetector(
                  onTap: busy ? null : onReplace,
                  child: _TileFrame(
                    child: url == null
                        ? Icon(Icons.image_outlined, color: ds.colors.textMuted)
                        : AppImage.path(url, cacheKey: url, memWidth: 240),
                  ),
                ),
              ),
              if (onDelete != null)
                Positioned(
                  top: ds.space.xs,
                  right: ds.space.xs,
                  child: _RoundTool(
                    icon: Icons.close,
                    label: tr(context, 'common.delete'),
                    onTap: busy ? null : onDelete,
                    danger: true,
                  ),
                ),
              Positioned(
                bottom: ds.space.xs,
                left: ds.space.xs,
                child: _RoundTool(
                  icon: Icons.auto_fix_high,
                  label: tr(context, 'detail.improvePhoto'),
                  onTap: busy ? null : onImprove,
                ),
              ),
              Positioned(
                bottom: ds.space.xs,
                right: ds.space.xs,
                child: _RoundTool(
                  icon: Icons.crop_rotate,
                  label: tr(context, 'detail.cropRotate'),
                  onTap: busy ? null : onCropRotate,
                ),
              ),
            ],
          ),
          SizedBox(height: ds.space.xs),
          Text(
            label.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ds.typo.monoSmall,
          ),
          SizedBox(height: ds.space.xs),
          Wrap(
            spacing: ds.space.xs,
            runSpacing: ds.space.xs,
            children: [
              photoStatusBadge(context, image),
              ?photoMethodBadge(context, image),
            ],
          ),
        ],
      ),
    );
  }
}

class _RoundTool extends StatelessWidget {
  const _RoundTool({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final c = context.ds.colors;
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        // 36 px visual, padded hit area from the surrounding gap.
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: danger ? c.danger : c.bg.withValues(alpha: 0.8),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 18, color: danger ? c.onAccent : c.text),
        ),
      ),
    );
  }
}
