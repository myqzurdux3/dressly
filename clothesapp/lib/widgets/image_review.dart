import 'package:flutter/material.dart';

import '../config/api_config.dart';
import '../l10n/app_text.dart';

/// Shared review UI for cloth photos: a crop-decision dialog that *shows* both
/// versions, an enhance-choice dialog (Auto/AI), an enhanced-preview dialog,
/// and a small badge telling how a photo was processed. Used by both the edit
/// form and the cloth detail screen.

Widget _labeledImage(BuildContext context, String label, String url,
    {Color? tint}) {
  return Column(mainAxisSize: MainAxisSize.min, children: [
    Text(label,
        style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: tint ?? Colors.white70)),
    const SizedBox(height: 6),
    GestureDetector(
      // Tap to view fullscreen with pinch-zoom.
      onTap: url.isEmpty ? null : () => showImageFullscreen(context, imageUrl(url)),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Container(
          height: 190,
          color: Colors.blueGrey.shade900,
          alignment: Alignment.center,
          child: url.isEmpty
              ? const Icon(Icons.image, color: Colors.white38)
              : Image.network(imageUrl(url),
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) =>
                      const Icon(Icons.broken_image, color: Colors.white54)),
        ),
      ),
    ),
  ]);
}

/// Shows the cut-out (background removed) next to the original photo and lets
/// the user pick which to keep. When [onChangeTolerance] is provided, a
/// Soft/Balanced/Strong selector re-runs removal and refreshes the cut-out.
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
  late String _cutoutUrl;
  late String _tolerance;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _cutoutUrl = widget.cutoutUrl;
    _tolerance = widget.tolerance;
  }

  Future<void> _setTolerance(String level) async {
    if (widget.onChangeTolerance == null || _busy || level == _tolerance) return;
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
      // Never let a failed re-run crash the dialog — keep the previous cut-out.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(tr(context, 'review.rerunFailed'))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr(context, 'review.cropTitle')),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // Order mirrors the action buttons below: Original on the left
          // ("Keep original"), Cut-out on the right ("Keep cut-out").
          Row(children: [
            Expanded(child: _labeledImage(context, tr(context, 'review.labelOriginal'), widget.originalUrl)),
            const SizedBox(width: 12),
            Expanded(child: _labeledImage(context, tr(context, 'review.labelCutout'), _cutoutUrl,
                tint: Colors.tealAccent)),
          ]),
          if (widget.onChangeTolerance != null) ...[
            const SizedBox(height: 10),
            Row(children: [
              Text(tr(context, 'review.strength'),
                  style: const TextStyle(fontSize: 12, color: Colors.white70)),
              const SizedBox(width: 8),
              Expanded(
                child: SegmentedButton<String>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 11))),
                  segments: [
                    ButtonSegment(value: 'low', label: Text(tr(context, 'review.soft'))),
                    ButtonSegment(value: 'medium', label: Text(tr(context, 'review.balanced'))),
                    ButtonSegment(value: 'high', label: Text(tr(context, 'review.strong'))),
                  ],
                  selected: {_tolerance},
                  onSelectionChanged:
                      _busy ? null : (s) => _setTolerance(s.first),
                ),
              ),
            ]),
            if (_busy) const LinearProgressIndicator(),
          ],
          const SizedBox(height: 8),
          Text(
              tr(context, 'review.strengthHint'),
              style: const TextStyle(color: Colors.grey, fontSize: 12)),
        ]),
      ),
      actions: [
        OutlinedButton(
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: Text(tr(context, 'review.keepOriginal')),
        ),
        FilledButton(
          onPressed: _busy ? null : () => Navigator.pop(context, true),
          child: Text(tr(context, 'review.keepCutout')),
        ),
      ],
    );
  }
}

/// Offers to improve the photo. Returns 'auto', 'ai', or null (skip).
Future<String?> showEnhanceChoice(BuildContext context) {
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(tr(ctx, 'review.improveTitle')),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.auto_fix_high),
          title: Text(tr(ctx, 'review.autoTitle')),
          subtitle: Text(tr(ctx, 'review.autoSubtitle')),
          onTap: () => Navigator.pop(ctx, 'auto'),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.auto_awesome),
          title: Text(tr(ctx, 'review.aiTitle')),
          subtitle: Text(tr(ctx, 'review.aiSubtitle')),
          onTap: () => Navigator.pop(ctx, 'ai'),
        ),
      ]),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, null),
          child: Text(tr(ctx, 'review.notNow')),
        ),
      ],
    ),
  );
}

String enhanceTierLabel(String tier) => const {
      'flex': 'Flex',
      'pro': 'Pro',
      'max': 'Max',
      'klein': 'Flex', // legacy
      'flux': 'Pro', // legacy
    }[tier] ??
    tier;

/// Shows the current photo next to the freshly-enhanced candidate so the user
/// can compare before/after. Returns 'keep', 'discard', or 'upgrade' (when a
/// better AI model is offered), or null if dismissed.
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
    builder: (ctx) => AlertDialog(
      title: Text(method == 'ai' ? tr(ctx, 'review.previewAiTitle') : tr(ctx, 'review.previewAutoTitle')),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Expanded(child: _labeledImage(ctx, tr(ctx, 'review.before'), currentUrl)),
            const SizedBox(width: 12),
            Expanded(child: _labeledImage(ctx, tr(ctx, 'review.after'), enhancedUrl, tint: Colors.tealAccent)),
          ]),
          const SizedBox(height: 8),
          Text(
              nextTier == null
                  ? tr(ctx, 'review.keepAfter')
                  : tr(ctx, 'review.keepOrTry'),
              style: const TextStyle(color: Colors.grey, fontSize: 12)),
        ]),
      ),
      actions: [
        OutlinedButton(
          onPressed: () => Navigator.pop(ctx, 'discard'),
          child: Text(tr(ctx, 'review.discard')),
        ),
        if (nextTier != null)
          OutlinedButton.icon(
            onPressed: () => Navigator.pop(ctx, 'upgrade'),
            icon: const Icon(Icons.upgrade, size: 18),
            label: Text('${tr(ctx, 'review.try')} ${enhanceTierLabel(nextTier)}'),
          ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, 'keep'),
          child: Text(tr(ctx, 'review.keep')),
        ),
      ],
    ),
  );
}

/// Opens a fullscreen, pinch-to-zoom view of an image. Pass a resolved URL.
void showImageFullscreen(BuildContext context, String url) {
  if (url.isEmpty) return;
  Navigator.of(context).push(PageRouteBuilder(
    opaque: false,
    barrierColor: Colors.black,
    pageBuilder: (_, __, ___) => Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black54),
      body: InteractiveViewer(
        minScale: 0.5,
        maxScale: 6,
        child: Center(
          child: Image.network(
            url,
            fit: BoxFit.contain,
            loadingBuilder: (context, child, p) =>
                p == null ? child : const Center(child: CircularProgressIndicator()),
            errorBuilder: (context, _, __) =>
                const Icon(Icons.broken_image, size: 64, color: Colors.white54),
          ),
        ),
      ),
    ),
  ));
}

/// Background-removal status pill. 'pending' shows the shared "Review" word
/// used everywhere a user choice is still needed.
class BgStatusBadge extends StatelessWidget {
  const BgStatusBadge({super.key, required this.status});
  final String status; // 'pending' | 'accepted' | 'rejected'

  @override
  Widget build(BuildContext context) {
    final (labelKey, color) = switch (status) {
      'accepted' => ('review.badgeCutout', Colors.green),
      'rejected' => ('review.badgeOriginal', Colors.blueGrey),
      _ => ('review.badgeReview', Colors.amber),
    };
    final label = tr(context, labelKey);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(label,
          style: const TextStyle(
              fontSize: 11, fontWeight: FontWeight.bold, color: Colors.black)),
    );
  }
}

/// A small pill showing how the photo was processed: AI, Auto or Original.
class EnhanceMethodBadge extends StatelessWidget {
  const EnhanceMethodBadge({super.key, required this.method});
  final String method; // 'none' | 'auto' | 'ai'

  @override
  Widget build(BuildContext context) {
    final (labelKey, color, icon) = switch (method) {
      'ai' => ('review.methodAi', Colors.purpleAccent, Icons.auto_awesome),
      'auto' => ('review.methodAuto', Colors.teal, Icons.auto_fix_high),
      _ => ('review.badgeOriginal', Colors.blueGrey, Icons.photo_camera),
    };
    final label = tr(context, labelKey);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 12, color: Colors.white),
        const SizedBox(width: 4),
        Text(label,
            style: const TextStyle(
                fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white)),
      ]),
    );
  }
}
