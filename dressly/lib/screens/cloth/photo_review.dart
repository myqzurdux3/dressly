import 'package:flutter/material.dart';

import '../../config/api_config.dart';
import '../../design/ds.dart';
import '../../l10n/app_text.dart';
import '../../widgets/app_image.dart';

/// Review steps for a garment photo, shared by the form and the detail
/// screen: the cut-out-or-original decision (shows both), the enhancement
/// choice, the enhanced before/after, and a fullscreen zoomable viewer.

/// Label over a picture; tap the picture for fullscreen.
class _LabeledImage extends StatelessWidget {
  const _LabeledImage({
    required this.label,
    required this.url,
    this.highlight = false,
  });

  final String label;
  final String url;

  /// The candidate (cut-out, enhanced): its label takes the accent.
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final c = ds.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label.toUpperCase(),
          style: ds.typo.monoSmall.copyWith(
            color: highlight ? c.accentText : c.textMuted,
          ),
        ),
        SizedBox(height: ds.space.xs),
        GestureDetector(
          onTap: url.isEmpty
              ? null
              : () => showImageFullscreen(context, imageUrl(url)),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(ds.shape.small),
            child: Container(
              height: 190,
              color: c.surfaceHigh,
              alignment: Alignment.center,
              child: url.isEmpty
                  ? Icon(Icons.image_outlined, color: c.textMuted)
                  // Cached: rebuilt on every accept/reject.
                  : AppImage(
                      url: imageUrl(url),
                      fit: BoxFit.contain,
                      memWidth: 800,
                    ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Shows the cut-out next to the original and lets the user pick which to
/// keep. With [onChangeTolerance], a Soft / Balanced / Strong choice re-runs
/// the removal and refreshes the cut-out in place.
/// Returns true = cut-out, false = original, null = dismissed.
Future<bool?> showCropDecision(
  BuildContext context, {
  required String cutoutUrl,
  required String originalUrl,
  String tolerance = 'medium',
  Future<String?> Function(String level)? onChangeTolerance,
}) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _CropDecisionDialog(
      cutoutUrl: cutoutUrl,
      originalUrl: originalUrl,
      tolerance: tolerance,
      onChangeTolerance: onChangeTolerance,
    ),
  );
}

class _CropDecisionDialog extends StatefulWidget {
  const _CropDecisionDialog({
    required this.cutoutUrl,
    required this.originalUrl,
    required this.tolerance,
    required this.onChangeTolerance,
  });

  final String cutoutUrl;
  final String originalUrl;
  final String tolerance;
  final Future<String?> Function(String level)? onChangeTolerance;

  @override
  State<_CropDecisionDialog> createState() => _CropDecisionDialogState();
}

class _CropDecisionDialogState extends State<_CropDecisionDialog> {
  late String _cutoutUrl = widget.cutoutUrl;
  late String _tolerance = widget.tolerance;
  bool _busy = false;

  Future<void> _setTolerance(String level) async {
    if (widget.onChangeTolerance == null || _busy || level == _tolerance) {
      return;
    }
    setState(() => _busy = true);
    try {
      final url = await widget.onChangeTolerance!(level);
      if (mounted && url != null) {
        setState(() {
          _cutoutUrl = url;
          _tolerance = level;
        });
      }
    } catch (_) {
      // A failed re-run must not close the decision: keep the last cut-out.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr(context, 'review.rerunFailed'))),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final c = ds.colors;
    return AlertDialog(
      title: Text(tr(context, 'review.cropTitle')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Same order as the buttons: original left, cut-out right.
            Row(
              children: [
                Expanded(
                  child: _LabeledImage(
                    label: tr(context, 'review.labelOriginal'),
                    url: widget.originalUrl,
                  ),
                ),
                SizedBox(width: ds.space.s),
                Expanded(
                  child: _LabeledImage(
                    label: tr(context, 'review.labelCutout'),
                    url: _cutoutUrl,
                    highlight: true,
                  ),
                ),
              ],
            ),
            if (widget.onChangeTolerance != null) ...[
              DsSectionTitle(tr(context, 'review.strength')),
              DsSegment<String>(
                options: [
                  ('low', tr(context, 'review.soft')),
                  ('medium', tr(context, 'review.balanced')),
                  ('high', tr(context, 'review.strong')),
                ],
                value: _tolerance,
                onChanged: _setTolerance,
              ),
              if (_busy) ...[
                SizedBox(height: ds.space.s),
                LinearProgressIndicator(
                  color: c.accent,
                  backgroundColor: c.surfaceHigh,
                ),
              ],
            ],
            SizedBox(height: ds.space.s),
            Text(
              tr(context, 'review.strengthHint'),
              style: ds.typo.label.copyWith(color: c.textMuted),
            ),
          ],
        ),
      ),
      actionsOverflowButtonSpacing: ds.space.s,
      actions: [
        DsButton(
          label: tr(context, 'review.keepOriginal'),
          kind: DsButtonKind.secondary,
          onPressed: _busy ? null : () => Navigator.pop(context, false),
        ),
        DsButton(
          label: tr(context, 'review.keepCutout'),
          onPressed: _busy ? null : () => Navigator.pop(context, true),
        ),
      ],
    );
  }
}

/// Offers to improve the photo. Returns 'auto', 'ai', or null (not now).
Future<String?> showEnhanceChoice(BuildContext context) {
  return showDsSheet<String>(
    context,
    title: tr(context, 'review.improveTitle'),
    child: Builder(
      builder: (ctx) {
        final ds = ctx.ds;
        Widget option(String mode, IconData icon, String title, String sub) =>
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(icon, color: ds.colors.accent),
              title: Text(tr(ctx, title), style: ds.typo.bodyStrong),
              subtitle: Text(
                tr(ctx, sub),
                style: ds.typo.label.copyWith(color: ds.colors.textMuted),
              ),
              onTap: () => Navigator.pop(ctx, mode),
            );
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            option(
              'auto',
              Icons.auto_fix_high,
              'review.autoTitle',
              'review.autoSubtitle',
            ),
            option(
              'ai',
              Icons.auto_awesome,
              'review.aiTitle',
              'review.aiSubtitle',
            ),
            SizedBox(height: ds.space.s),
            DsButton(
              label: tr(ctx, 'review.notNow'),
              kind: DsButtonKind.secondary,
              expand: true,
              onPressed: () => Navigator.pop(ctx),
            ),
          ],
        );
      },
    ),
  );
}

String enhanceTierLabel(String tier) =>
    const {
      'flex': 'Flex',
      'pro': 'Pro',
      'max': 'Max',
      'klein': 'Flex', // legacy
      'flux': 'Pro', // legacy
    }[tier] ??
    tier;

/// The current photo next to the enhanced candidate. Returns 'keep',
/// 'discard', 'upgrade' (when a better AI model is offered) or null.
Future<String?> showEnhancePreview(
  BuildContext context, {
  required String currentUrl,
  required String enhancedUrl,
  required String method,
  String? nextTier,
}) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) {
      final ds = ctx.ds;
      return AlertDialog(
        title: Text(
          tr(
            ctx,
            method == 'ai'
                ? 'review.previewAiTitle'
                : 'review.previewAutoTitle',
          ),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: _LabeledImage(
                      label: tr(ctx, 'review.before'),
                      url: currentUrl,
                    ),
                  ),
                  SizedBox(width: ds.space.s),
                  Expanded(
                    child: _LabeledImage(
                      label: tr(ctx, 'review.after'),
                      url: enhancedUrl,
                      highlight: true,
                    ),
                  ),
                ],
              ),
              SizedBox(height: ds.space.s),
              Text(
                tr(
                  ctx,
                  nextTier == null ? 'review.keepAfter' : 'review.keepOrTry',
                ),
                style: ds.typo.label.copyWith(color: ds.colors.textMuted),
              ),
            ],
          ),
        ),
        actionsOverflowButtonSpacing: ds.space.s,
        actions: [
          DsButton(
            label: tr(ctx, 'review.discard'),
            kind: DsButtonKind.secondary,
            onPressed: () => Navigator.pop(ctx, 'discard'),
          ),
          if (nextTier != null)
            DsButton(
              label: '${tr(ctx, 'review.try')} ${enhanceTierLabel(nextTier)}',
              icon: Icons.upgrade,
              kind: DsButtonKind.secondary,
              onPressed: () => Navigator.pop(ctx, 'upgrade'),
            ),
          DsButton(
            label: tr(ctx, 'review.keep'),
            onPressed: () => Navigator.pop(ctx, 'keep'),
          ),
        ],
      );
    },
  );
}

/// Fullscreen, pinch-to-zoom view of an image. Pass a resolved URL.
void showImageFullscreen(BuildContext context, String url) {
  if (url.isEmpty) return;
  Navigator.of(context).push(
    PageRouteBuilder<void>(
      opaque: false,
      pageBuilder: (context, _, _) {
        final ds = context.ds;
        return Scaffold(
          backgroundColor: ds.colors.bg,
          body: Stack(
            children: [
              InteractiveViewer(
                minScale: 0.5,
                maxScale: 6,
                child: Center(
                  // Zoomable, so the stored image — through the cache.
                  child: AppImage(url: url, fit: BoxFit.contain),
                ),
              ),
              SafeArea(
                child: Padding(
                  padding: EdgeInsets.all(ds.space.s),
                  child: DsButton.icon(
                    icon: Icons.close,
                    semanticLabel: MaterialLocalizations.of(
                      context,
                    ).closeButtonTooltip,
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}
