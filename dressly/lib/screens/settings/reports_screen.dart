import 'package:flutter/material.dart';

import '../../app.dart';
import '../../design/ds.dart';
import '../../l10n/app_text.dart';
import '../../models/outfit.dart' show modelTierLabel;
import '../../models/report.dart';
import '../../widgets/app_image.dart';
import '../../widgets/error_toast.dart';

/// What users reported from the app: bad cut-outs (with the photo) and bad
/// generations. Admin-only: the server refuses anyone else.
///
/// Cut-out reports can be marked as handled; the server has no such route for
/// generation reports, so those are listed only.
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key, this.imageBuilder});

  /// Builds a report's photo from its relative path. Tests swap it for a
  /// placeholder so no image is fetched; null uses [AppImage].
  final Widget Function(String path)? imageBuilder;

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  List<UserReport> _cutouts = const [];
  List<UserReport> _generations = const [];
  Object? _error;
  bool _loading = true;

  /// Ids of cut-out reports being marked as handled.
  final Set<int> _resolving = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final svc = adminServiceOf(context);
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        svc.cutoutReports(),
        svc.generationReports(),
      ]);
      if (!mounted) return;
      setState(() {
        _cutouts = results[0];
        _generations = results[1];
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _resolve(UserReport r) async {
    final svc = adminServiceOf(context);
    setState(() => _resolving.add(r.id));
    try {
      await svc.resolveCutoutReport(r.id);
      if (!mounted) return;
      setState(() {
        _cutouts = [
          for (final x in _cutouts)
            x.id == r.id
                ? UserReport(
                    id: x.id,
                    kind: x.kind,
                    message: x.message,
                    resolved: true,
                    createdAt: x.createdAt,
                    reporterEmail: x.reporterEmail,
                    imageUrl: x.imageUrl,
                    clothName: x.clothName,
                  )
                : x,
        ];
      });
    } catch (e) {
      toastError(e, prefixKey: 'reports.resolveFailed');
    } finally {
      if (mounted) setState(() => _resolving.remove(r.id));
    }
  }

  /// The report's timestamp as a localized medium date and time.
  String _when(UserReport r) {
    final dt = r.createdAtLocal;
    if (dt == null) return r.createdAt;
    final loc = MaterialLocalizations.of(context);
    final time = loc.formatTimeOfDay(
      TimeOfDay.fromDateTime(dt),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
    return '${loc.formatMediumDate(dt)} · $time';
  }

  @override
  Widget build(BuildContext context) {
    return DsSubPage(
      title: tr(context, 'reports.title'),
      onRefresh: _load,
      actions: [
        DsButton.icon(
          icon: Icons.refresh,
          semanticLabel: tr(context, 'credits.refresh'),
          onPressed: _loading ? null : _load,
        ),
      ],
      children: _body(),
    );
  }

  List<Widget> _body() {
    final ds = context.ds;
    if (_loading && _cutouts.isEmpty && _generations.isEmpty) {
      return [
        Padding(
          padding: EdgeInsets.all(ds.space.xl),
          child: Center(
            child: CircularProgressIndicator(color: ds.colors.accent),
          ),
        ),
      ];
    }
    if (_error != null) {
      return [
        DsError(
          message: errorMessage(
            context,
            _error!,
            prefixKey: 'reports.loadError',
          ),
          retryLabel: tr(context, 'common.retry'),
          onRetry: _load,
        ),
      ];
    }
    if (_cutouts.isEmpty && _generations.isEmpty) {
      return [
        DsEmpty(
          title: tr(context, 'reports.emptyTitle'),
          message: tr(context, 'reports.emptyMessage'),
        ),
      ];
    }
    return [
      if (_cutouts.isNotEmpty) ...[
        DsSectionTitle(tr(context, 'reports.cutouts')),
        for (final r in _cutouts) _card(r),
      ],
      if (_generations.isNotEmpty) ...[
        DsSectionTitle(tr(context, 'reports.generations')),
        for (final r in _generations) _card(r),
      ],
    ];
  }

  Widget _card(UserReport r) {
    final ds = context.ds;
    final col = ds.colors;
    final kind = tr(
      context,
      r.kind == ReportKind.cutout
          ? 'reports.kindCutout'
          : 'reports.kindGeneration',
    );
    final subject = r.kind == ReportKind.cutout
        ? r.clothName
        : [
            if (r.tier.isNotEmpty) modelTierLabel(r.tier),
            if (r.outfitId != null)
              tr(context, 'reports.outfit', {'id': '${r.outfitId}'}),
          ].join(' · ');
    final meta = [
      _when(r),
      if (r.reporterEmail.isNotEmpty)
        tr(context, 'reports.by', {'email': r.reporterEmail}),
    ].join(' · ');
    final muted = ds.typo.label.copyWith(color: col.textMuted);

    return Padding(
      key: ValueKey('report-${r.kind.name}-${r.id}'),
      padding: EdgeInsets.only(bottom: ds.space.xs),
      child: Container(
        padding: EdgeInsets.all(ds.space.m),
        decoration: BoxDecoration(
          color: col.surface,
          borderRadius: ds.shape.cardRadius,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (r.imageUrl.isNotEmpty) ...[
              ClipRRect(
                borderRadius: ds.shape.smallRadius,
                child: SizedBox(
                  width: 64,
                  height: 64,
                  child: widget.imageBuilder?.call(r.imageUrl) ??
                      AppImage.path(r.imageUrl, fit: BoxFit.cover),
                ),
              ),
              SizedBox(width: ds.space.s),
            ] else ...[
              Icon(
                r.kind == ReportKind.cutout
                    ? Icons.content_cut
                    : Icons.auto_awesome,
                color: col.accentText,
              ),
              SizedBox(width: ds.space.s),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          subject.isEmpty ? kind : '$kind · $subject',
                          style: ds.typo.bodyStrong,
                        ),
                      ),
                      if (r.resolved)
                        DsBadge(text: tr(context, 'reports.resolved')),
                    ],
                  ),
                  Text(meta, style: muted),
                  SizedBox(height: ds.space.xs),
                  Text(
                    r.message.trim().isEmpty
                        ? tr(context, 'reports.noComment')
                        : r.message.trim(),
                    style: r.message.trim().isEmpty ? muted : ds.typo.body,
                  ),
                  if (r.canResolve) ...[
                    SizedBox(height: ds.space.s),
                    DsButton(
                      label: tr(context, 'reports.resolve'),
                      icon: Icons.check,
                      kind: DsButtonKind.secondary,
                      loading: _resolving.contains(r.id),
                      onPressed: () => _resolve(r),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
