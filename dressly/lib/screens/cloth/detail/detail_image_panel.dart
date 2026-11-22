import 'package:flutter/material.dart';

import '../../../config/api_config.dart';
import '../../../design/ds.dart';
import '../../../l10n/app_text.dart';
import '../../../models/cloth.dart';
import '../../../widgets/app_image.dart';
import '../photo_review.dart'
    show enhanceTierLabel, showCropDecision, showImageFullscreen;

/// Draws one network image. Injected so tests need no network.
typedef DetailImageBuilder =
    Widget Function(String url, String cacheKey, int memWidth);

Widget detailAppImage(String url, String cacheKey, int memWidth) => AppImage(
  url: url,
  cacheKey: cacheKey,
  fit: BoxFit.contain,
  memWidth: memWidth,
);

/// The badge over a photo: its side, in the app's language. The server says
/// "front" / "back" / "extra"; printed raw, a French app showed "FRONT".
String roleLabel(BuildContext context, String role) => switch (role) {
  'front' => tr(context, 'form.front'),
  'back' => tr(context, 'form.back'),
  _ => tr(context, 'form.photo'),
};

/// Where the photo's background removal stands: being made, failed, cut-out
/// kept, original kept, or waiting for the user's choice (accent).
Widget photoStatusBadge(BuildContext context, ClothImage image) {
  if (image.cutoutStatus == 'processing') {
    return DsBadge(
      text: tr(context, 'review.badgeProcessing'),
      tone: DsBadgeTone.accent,
    );
  }
  if (image.cutoutStatus == 'failed') {
    return DsBadge(
      text: tr(context, 'review.badgeCutoutFailed'),
      tone: DsBadgeTone.accent,
    );
  }
  return switch (image.bgAccepted) {
    'accepted' => DsBadge(text: tr(context, 'review.badgeCutout')),
    'rejected' => DsBadge(text: tr(context, 'review.badgeOriginal')),
    _ => DsBadge(
      text: tr(context, 'review.badgeReview'),
      tone: DsBadgeTone.accent,
    ),
  };
}

/// How the photo was enhanced, or null when it was not.
Widget? photoMethodBadge(BuildContext context, ClothImage image) =>
    switch (image.enhanceMethod) {
      'ai' => DsBadge(text: tr(context, 'review.methodAi')),
      'auto' => DsBadge(text: tr(context, 'review.methodAuto')),
      _ => null,
    };

/// One photo of the garment and every tool that applies to it: crop, cut-out
/// strength, the cut-out-or-original decision, enhancement, report.
class DetailImagePanel extends StatelessWidget {
  const DetailImagePanel({
    super.key,
    required this.image,
    required this.busy,
    required this.onDecide,
    required this.onCropRotate,
    required this.onTolerance,
    required this.onEnhance,
    required this.onDescribeChanged,
    required this.onAcceptEnhance,
    required this.onRejectEnhance,
    required this.onReport,
    this.imageBuilder = detailAppImage,
  });

  final ClothImage image;

  /// A cut-out call for this photo is in flight: its controls are disabled.
  final bool busy;

  /// true = keep the cut-out, false = keep the original.
  final ValueChanged<bool> onDecide;
  final VoidCallback onCropRotate;
  final ValueChanged<String> onTolerance;

  /// (mode, tier). Mode is 'auto' or 'ai'.
  final void Function(String mode, String tier) onEnhance;
  final ValueChanged<bool> onDescribeChanged;
  final VoidCallback onAcceptEnhance;
  final VoidCallback onRejectEnhance;
  final VoidCallback onReport;
  final DetailImageBuilder imageBuilder;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final c = ds.colors;
    final accepted = image.bgAccepted == 'accepted';
    final rejected = image.bgAccepted == 'rejected';
    // Once made, the choice is final: only a pending photo offers it.
    final decided = accepted || rejected;
    final gap = SizedBox(height: ds.space.m);
    final preview = image.displayPreviewUrl ?? image.originalPreview;

    return Container(
      margin: EdgeInsets.only(bottom: ds.space.m),
      padding: EdgeInsets.all(ds.space.m),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(ds.shape.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: ds.space.xs,
            runSpacing: ds.space.xs,
            children: [
              DsBadge(text: roleLabel(context, image.role)),
              photoStatusBadge(context, image),
              ?photoMethodBadge(context, image),
            ],
          ),
          SizedBox(height: ds.space.s),
          Semantics(
            button: true,
            label: tr(context, 'form.photo'),
            child: GestureDetector(
              onTap: () =>
                  showImageFullscreen(context, imageUrl(image.displayUrl)),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(ds.shape.small),
                child: ColoredBox(
                  color: c.surfaceHigh,
                  child: SizedBox(
                    height: 280,
                    // The 800 px preview: indistinguishable here, a twelfth
                    // of the transfer of the stored image.
                    child: imageBuilder(
                      imageUrl(preview),
                      'img-${image.id}-${image.bgAccepted}-$preview',
                      800,
                    ),
                  ),
                ),
              ),
            ),
          ),
          SizedBox(height: ds.space.s),
          Align(
            alignment: Alignment.centerLeft,
            child: DsButton(
              label: tr(context, 'detail.cropRotate'),
              icon: Icons.crop_rotate,
              kind: DsButtonKind.secondary,
              onPressed: busy ? null : onCropRotate,
            ),
          ),
          gap,
          Text(
            tr(context, 'detail.cutoutStrength').toUpperCase(),
            style: ds.typo.monoSmall.copyWith(color: c.textMuted),
          ),
          SizedBox(height: ds.space.xs),
          DsSegment<String>(
            options: [
              ('low', tr(context, 'detail.soft')),
              ('medium', tr(context, 'detail.balanced')),
              ('high', tr(context, 'detail.strong')),
            ],
            value: image.bgTolerance,
            onChanged: (level) {
              if (!busy && level != image.bgTolerance) onTolerance(level);
            },
          ),
          SizedBox(height: ds.space.xs),
          Text(
            tr(context, 'detail.strengthHint'),
            style: ds.typo.label.copyWith(color: c.textMuted),
          ),
          gap,
          if (busy)
            Center(
              child: SizedBox.square(
                dimension: ds.space.l,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: c.accent,
                ),
              ),
            )
          else if (decided)
            Row(
              children: [
                Icon(
                  accepted ? Icons.check_circle : Icons.image_outlined,
                  size: 18,
                  color: c.olive,
                ),
                SizedBox(width: ds.space.s),
                Expanded(
                  child: Text(
                    tr(
                      context,
                      accepted ? 'detail.usingCutout' : 'detail.usingOriginal',
                    ),
                    style: ds.typo.body.copyWith(color: c.textMuted),
                  ),
                ),
                Icon(Icons.lock_outline, size: 16, color: c.textMuted),
              ],
            )
          else
            DsButton(
              label: tr(context, 'detail.chooseCropShort'),
              icon: Icons.compare,
              expand: true,
              onPressed: () async {
                final keepCutout = await showCropDecision(
                  context,
                  cutoutUrl: image.cutoutPreview,
                  originalUrl: image.originalPreview,
                );
                if (keepCutout != null) onDecide(keepCutout);
              },
            ),
          Divider(height: ds.space.xl, color: c.hairline),
          _EnhanceSection(panel: this),
          SizedBox(height: ds.space.s),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: onReport,
              style: TextButton.styleFrom(foregroundColor: c.textMuted),
              icon: const Icon(Icons.flag_outlined, size: 16),
              label: Text(
                tr(context, 'detail.reportTitle'),
                style: ds.typo.label,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Opt-in photo enhancement: the method chooser when idle, progress while it
/// runs, before/after with keep or discard when ready, and the ways forward
/// when it failed.
class _EnhanceSection extends StatelessWidget {
  const _EnhanceSection({required this.panel});

  final DetailImagePanel panel;

  ClothImage get image => panel.image;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final c = ds.colors;
    final gap = SizedBox(height: ds.space.s);
    final status = image.enhanceStatus;

    if (status == 'processing') {
      // The server gives up on its own, but a retry is offered anyway: it is
      // the one useful thing to do with a run that takes too long.
      return Row(
        children: [
          SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(strokeWidth: 2, color: c.accent),
          ),
          SizedBox(width: ds.space.s),
          Expanded(
            child: Text(
              tr(context, 'detail.enhancing'),
              style: ds.typo.body.copyWith(color: c.textMuted),
            ),
          ),
          DsButton(
            label: tr(context, 'detail.enhanceRetry'),
            kind: DsButtonKind.secondary,
            onPressed: () =>
                panel.onEnhance(image.enhancePendingMethod ?? 'auto', 'flex'),
          ),
        ],
      );
    }

    if (status == 'ready' && image.enhancedUrl.isNotEmpty) {
      final next = image.enhanceNextTier;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            tr(context, 'detail.enhancedCompare'),
            style: ds.typo.bodyStrong,
          ),
          gap,
          Row(
            children: [
              Expanded(
                child: _tile(
                  context,
                  tr(context, 'detail.before'),
                  image.displayPreviewUrl ?? image.originalPreview,
                ),
              ),
              SizedBox(width: ds.space.s),
              Expanded(
                child: _tile(
                  context,
                  tr(context, 'detail.after'),
                  image.enhancedPreview,
                ),
              ),
            ],
          ),
          gap,
          Row(
            children: [
              Expanded(
                child: DsButton(
                  label: tr(context, 'detail.keep'),
                  icon: Icons.check,
                  expand: true,
                  onPressed: panel.onAcceptEnhance,
                ),
              ),
              SizedBox(width: ds.space.s),
              Expanded(
                child: DsButton(
                  label: tr(context, 'detail.discard'),
                  icon: Icons.close,
                  kind: DsButtonKind.secondary,
                  expand: true,
                  onPressed: panel.onRejectEnhance,
                ),
              ),
            ],
          ),
          if (image.enhancePendingMethod == 'ai' && next != null) ...[
            gap,
            DsButton(
              label: tr(context, 'detail.tryBetterModel', {
                'tier': enhanceTierLabel(next),
              }),
              icon: Icons.upgrade,
              kind: DsButtonKind.secondary,
              expand: true,
              onPressed: () => panel.onEnhance('ai', next),
            ),
          ],
        ],
      );
    }

    if (status == 'failed') {
      // Reported: some garments "mettent sans cesse fail même après
      // réessayer". Repeating the identical request is what does not help, so
      // the step up to a stronger model sits next to it, with the server's
      // own reason.
      final next = image.enhanceNextTier;
      final last = image.enhancePendingMethod ?? 'auto';
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.error_outline, size: 18, color: c.danger),
              SizedBox(width: ds.space.xs),
              Expanded(
                child: Text(
                  tr(context, 'detail.enhanceTimedOut'),
                  style: ds.typo.label.copyWith(color: c.danger),
                ),
              ),
            ],
          ),
          if ((image.enhanceError ?? '').isNotEmpty)
            Padding(
              padding: EdgeInsets.only(top: ds.space.xs),
              child: Text(
                // Errors stored before the server stopped sending them still
                // carry its file paths: never show those.
                image.enhanceError!.replaceAll(
                  RegExp(r"(/[\w.\-]+){2,}'?"),
                  '…',
                ),
                style: ds.typo.monoSmall.copyWith(color: c.textMuted),
              ),
            ),
          gap,
          Wrap(
            spacing: ds.space.s,
            runSpacing: ds.space.s,
            children: [
              DsButton(
                label: tr(context, 'detail.enhanceRetry'),
                icon: Icons.refresh,
                kind: DsButtonKind.secondary,
                onPressed: () => panel.onEnhance(last, 'flex'),
              ),
              if (next != null)
                DsButton(
                  label: tr(context, 'detail.enhanceRetryStronger', {
                    'tier': enhanceTierLabel(next),
                  }),
                  icon: Icons.upgrade,
                  onPressed: () => panel.onEnhance('ai', next),
                )
              else if (last != 'ai')
                // The deterministic pass failed; AI is another engine
                // entirely, so it is worth offering rather than repeating.
                DsButton(
                  label: tr(context, 'detail.enhanceTryAi'),
                  icon: Icons.auto_awesome,
                  onPressed: () => panel.onEnhance('ai', 'flex'),
                ),
              _methodButton(context, tr(context, 'detail.otherMethod')),
            ],
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Next to the button, not behind a dialog: one tap, remembered per
        // photo, and it only changes what the AI pass is told.
        InkWell(
          onTap: () => panel.onDescribeChanged(!image.enhanceDescribe),
          child: Row(
            children: [
              Checkbox(
                value: image.enhanceDescribe,
                activeColor: c.accent,
                checkColor: c.onAccent,
                onChanged: (v) => panel.onDescribeChanged(v ?? true),
              ),
              Expanded(
                child: Text(
                  tr(context, 'detail.describeItem'),
                  style: ds.typo.label.copyWith(color: c.textMuted),
                ),
              ),
            ],
          ),
        ),
        gap,
        _methodButton(context, tr(context, 'detail.improvePhoto')),
      ],
    );
  }

  /// Opens the Auto / AI chooser.
  Widget _methodButton(BuildContext context, String label) => DsButton(
    label: label,
    icon: Icons.auto_fix_high,
    kind: DsButtonKind.secondary,
    onPressed: () async {
      final mode = await showDsSheet<String>(
        context,
        title: label,
        child: const _MethodChoice(),
      );
      if (mode != null) panel.onEnhance(mode, 'flex');
    },
  );

  Widget _tile(BuildContext context, String label, String url) {
    final ds = context.ds;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: ds.typo.monoSmall.copyWith(color: ds.colors.textMuted),
        ),
        SizedBox(height: ds.space.xs),
        GestureDetector(
          onTap: () => showImageFullscreen(context, imageUrl(url)),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(ds.shape.small),
            child: ColoredBox(
              color: ds.colors.surfaceHigh,
              child: SizedBox(
                height: 170,
                child: panel.imageBuilder(imageUrl(url), 'ba-$url', 800),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _MethodChoice extends StatelessWidget {
  const _MethodChoice();

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    Widget option(String mode, IconData icon, String title, String sub) =>
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(icon, color: ds.colors.accent),
          title: Text(tr(context, title), style: ds.typo.bodyStrong),
          subtitle: Text(
            tr(context, sub),
            style: ds.typo.label.copyWith(color: ds.colors.textMuted),
          ),
          onTap: () => Navigator.pop(context, mode),
        );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        option(
          'auto',
          Icons.auto_fix_high,
          'detail.autoCleanup',
          'detail.autoCleanupSub',
        ),
        option(
          'ai',
          Icons.auto_awesome,
          'detail.aiEnhance',
          'detail.aiEnhanceSub',
        ),
      ],
    );
  }
}
