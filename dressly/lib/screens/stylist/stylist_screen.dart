import 'package:flutter/material.dart';

import '../../app.dart';
import '../../design/ds.dart';
import '../../l10n/app_text.dart';
import '../../models/stylist.dart';
import '../../services/stylist_service.dart';
import '../../widgets/app_image.dart';
import '../outfit/outfit_result_dialog.dart';

/// The personal stylist: a conversation with an assistant that sees the
/// wardrobe, the ratings, the agenda and the forecast, and proposes outfits
/// the user can add to their outfits with one tap.
class StylistScreen extends StatefulWidget {
  const StylistScreen({super.key});

  @override
  State<StylistScreen> createState() => _StylistScreenState();
}

class _StylistScreenState extends State<StylistScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  bool? _available;
  int? _threadId;
  List<StylistMessage> _messages = [];

  /// The question in flight, shown until the server's copy comes back.
  String? _sending;
  bool _loadingThread = false;

  /// Proposals being saved, so their button shows a spinner.
  final Set<int> _saving = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkAvailable());
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _checkAvailable() async {
    try {
      final ok = await stylistServiceOf(context).available();
      if (mounted) setState(() => _available = ok);
    } catch (_) {
      if (mounted) setState(() => _available = false);
    }
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _send([String? preset]) async {
    final text = (preset ?? _input.text).trim();
    if (text.isEmpty || _sending != null) return;
    final svc = stylistServiceOf(context);
    setState(() {
      _sending = text;
      _input.clear();
    });
    try {
      final id = await svc.send(text, threadId: _threadId);
      _threadId = id;
      final thread = await svc.waitForReply(id);
      if (!mounted) return;
      setState(() {
        _messages = thread.messages;
        _sending = null;
      });
      if (thread.error.isNotEmpty) {
        // The server dropped the question: give it back to edit or resend.
        _input.text = text;
        _toast(thread.error);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = null);
      _input.text = text;
      _toast('$e');
    }
  }

  void _newConversation() {
    if (_sending != null) return;
    setState(() {
      _threadId = null;
      _messages = [];
    });
  }

  Future<void> _openHistory() async {
    if (_sending != null) return;
    final svc = stylistServiceOf(context);
    List<StylistThread> threads;
    try {
      threads = await svc.threads();
    } catch (e) {
      _toast('$e');
      return;
    }
    if (!mounted) return;
    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _HistorySheet(threads: threads, service: svc),
    );
    if (picked == null || !mounted) return;
    setState(() => _loadingThread = true);
    try {
      final t = await svc.thread(picked);
      if (!mounted) return;
      setState(() {
        _threadId = t.id;
        _messages = t.messages;
        _loadingThread = false;
      });
    } catch (e) {
      if (mounted) setState(() => _loadingThread = false);
      _toast('$e');
    }
  }

  Future<void> _save(StylistMessage m, StylistProposal p) async {
    final svc = stylistServiceOf(context);
    final saved = tr(context, 'stylist.saved');
    setState(() => _saving.add(p.id));
    try {
      final outfitId = await svc.saveProposal(p.id);
      if (!mounted) return;
      setState(() {
        _saving.remove(p.id);
        _messages = [
          for (final x in _messages)
            x.id != m.id
                ? x
                : StylistMessage(
                    id: x.id,
                    role: x.role,
                    text: x.text,
                    proposals: [
                      for (final q in x.proposals)
                        q.id == p.id ? q.saved(outfitId) : q,
                    ],
                  ),
        ];
      });
      _toast(saved);
    } catch (e) {
      if (mounted) setState(() => _saving.remove(p.id));
      _toast('$e');
    }
  }

  Future<void> _openOutfit(int outfitId) async {
    try {
      final o = await outfitsServiceOf(context).get(outfitId);
      if (!mounted) return;
      await showDialog<bool>(
        context: context,
        builder: (_) => OutfitResultDialog(outfit: o, onChanged: (_) {}),
      );
    } catch (e) {
      _toast('$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final c = ds.colors;
    final busy = _sending != null;
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                ds.space.gutter,
                ds.space.s,
                ds.space.gutter,
                ds.space.xs,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      tr(context, 'stylist.title').toUpperCase(),
                      style: ds.typo.headline,
                    ),
                  ),
                  DsButton.icon(
                    icon: Icons.history,
                    semanticLabel: tr(context, 'stylist.history'),
                    onPressed: busy || _available != true ? null : _openHistory,
                  ),
                  SizedBox(width: ds.space.xs),
                  DsButton.icon(
                    icon: Icons.add_comment_outlined,
                    semanticLabel: tr(context, 'stylist.new'),
                    onPressed: busy || _messages.isEmpty
                        ? null
                        : _newConversation,
                  ),
                ],
              ),
            ),
            Expanded(child: _body()),
            if (_available == true) _inputBar(),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    final ds = context.ds;
    if (_available == null || _loadingThread) {
      return Center(child: CircularProgressIndicator(color: ds.colors.accent));
    }
    if (_available == false) {
      return DsEmpty(
        title: tr(context, 'stylist.offTitle'),
        message: tr(context, 'stylist.offMessage'),
        actionLabel: tr(context, 'common.retry'),
        onAction: () {
          setState(() => _available = null);
          _checkAvailable();
        },
      );
    }
    if (_messages.isEmpty && _sending == null) return _suggestions();
    final items = <Widget>[
      for (final m in _messages) _bubble(m),
      if (_sending != null) ...[
        _bubble(StylistMessage(id: -1, role: 'user', text: _sending!)),
        _thinking(),
      ],
    ];
    // Reversed so the newest message sits above the input, and new ones
    // appear without scrolling.
    return ListView.builder(
      controller: _scroll,
      reverse: true,
      padding: EdgeInsets.fromLTRB(
        ds.space.gutter,
        ds.space.s,
        ds.space.gutter,
        ds.space.s,
      ),
      itemCount: items.length,
      itemBuilder: (_, i) => items[items.length - 1 - i],
    );
  }

  Widget _suggestions() {
    final ds = context.ds;
    final c = ds.colors;
    final prompts = [
      tr(context, 'stylist.ask1'),
      tr(context, 'stylist.ask2'),
      tr(context, 'stylist.ask3'),
      tr(context, 'stylist.ask4'),
    ];
    return ListView(
      padding: EdgeInsets.all(ds.space.gutter),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Icon(Icons.checkroom, size: 40, color: c.accentText),
        ),
        SizedBox(height: ds.space.s),
        Text(tr(context, 'stylist.intro'), style: ds.typo.title),
        SizedBox(height: ds.space.xs),
        Text(
          tr(context, 'stylist.introHint'),
          style: ds.typo.label.copyWith(color: c.textMuted),
        ),
        SizedBox(height: ds.space.l),
        for (final p in prompts)
          Padding(
            padding: EdgeInsets.only(bottom: ds.space.xs),
            child: DsPressable(
              onTap: () => _send(p),
              child: Container(
                padding: EdgeInsets.all(ds.space.m),
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: ds.shape.cardRadius,
                ),
                child: Row(
                  children: [
                    Expanded(child: Text(p, style: ds.typo.body)),
                    Icon(Icons.arrow_forward, size: 18, color: c.textMuted),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _thinking() {
    final ds = context.ds;
    final c = ds.colors;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: EdgeInsets.only(bottom: ds.space.s),
        padding: EdgeInsets.symmetric(
          horizontal: ds.space.m,
          vertical: ds.space.s,
        ),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: ds.shape.cardRadius,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2, color: c.accent),
            ),
            SizedBox(width: ds.space.s),
            Text(
              tr(context, 'stylist.thinking'),
              style: ds.typo.label.copyWith(color: c.textMuted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bubble(StylistMessage m) {
    final ds = context.ds;
    final c = ds.colors;
    final width = MediaQuery.sizeOf(context).width;
    final bubble = Container(
      constraints: BoxConstraints(maxWidth: width * 0.82),
      padding: EdgeInsets.symmetric(
        horizontal: ds.space.m,
        vertical: ds.space.s,
      ),
      decoration: BoxDecoration(
        color: m.isUser ? c.accent : c.surface,
        borderRadius: ds.shape.cardRadius,
      ),
      child: m.isUser
          ? Text(m.text, style: ds.typo.body.copyWith(color: c.onAccent))
          : _RichReply(text: m.text),
    );
    return Padding(
      padding: EdgeInsets.only(bottom: ds.space.s),
      child: Column(
        crossAxisAlignment: m.isUser
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          bubble,
          for (final p in m.proposals)
            Padding(
              padding: EdgeInsets.only(top: ds.space.xs),
              child: _ProposalCard(
                proposal: p,
                saving: _saving.contains(p.id),
                onSave: () => _save(m, p),
                onOpen: p.outfitId == null
                    ? null
                    : () => _openOutfit(p.outfitId!),
              ),
            ),
        ],
      ),
    );
  }

  Widget _inputBar() {
    final ds = context.ds;
    final c = ds.colors;
    final busy = _sending != null;
    return Container(
      padding: EdgeInsets.fromLTRB(
        ds.space.gutter,
        ds.space.xs,
        ds.space.gutter,
        ds.space.s,
      ),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: c.hairline)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: _input,
              enabled: !busy,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(),
              decoration: InputDecoration(
                hintText: tr(context, 'stylist.inputHint'),
              ),
            ),
          ),
          SizedBox(width: ds.space.xs),
          DsButton.icon(
            icon: Icons.send,
            semanticLabel: tr(context, 'stylist.send'),
            onPressed: busy ? null : _send,
          ),
        ],
      ),
    );
  }
}

/// The stylist's text with the little markdown it uses: **bold** and "- "
/// bullets. Anything else is shown as written.
class _RichReply extends StatelessWidget {
  const _RichReply({required this.text});
  final String text;

  List<InlineSpan> _spans(String line, TextStyle base) {
    final parts = line.split('**');
    return [
      for (var i = 0; i < parts.length; i++)
        TextSpan(
          text: parts[i],
          style: i.isOdd ? base.copyWith(fontWeight: FontWeight.w700) : base,
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final base = ds.typo.body.copyWith(color: ds.colors.text);
    final lines = text.split('\n');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final raw in lines)
          if (raw.trim().isEmpty)
            SizedBox(height: ds.space.xs)
          else
            () {
              var line = raw.trimRight();
              final bullet = RegExp(r'^\s*[-*•]\s+').firstMatch(line);
              final heading = RegExp(r'^\s*#+\s+').firstMatch(line);
              if (heading != null) line = line.substring(heading.end);
              final style = heading != null
                  ? base.copyWith(fontWeight: FontWeight.w700)
                  : base;
              if (bullet == null) {
                return Text.rich(TextSpan(children: _spans(line, style)));
              }
              return Padding(
                padding: EdgeInsets.only(left: ds.space.xs),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('•  ', style: style),
                    Expanded(
                      child: Text.rich(
                        TextSpan(
                          children: _spans(line.substring(bullet.end), style),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }(),
      ],
    );
  }
}

class _ProposalCard extends StatelessWidget {
  const _ProposalCard({
    required this.proposal,
    required this.saving,
    required this.onSave,
    this.onOpen,
  });

  final StylistProposal proposal;
  final bool saving;
  final VoidCallback onSave;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final c = ds.colors;
    final saved = proposal.outfitId != null;
    return Container(
      padding: EdgeInsets.all(ds.space.m),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: ds.shape.cardRadius,
        border: Border.all(color: saved ? c.accent : c.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(proposal.title.toUpperCase(), style: ds.typo.title),
          if (proposal.reason.isNotEmpty) ...[
            SizedBox(height: ds.space.xs / 2),
            Text(
              proposal.reason,
              style: ds.typo.label.copyWith(color: c.textMuted),
            ),
          ],
          SizedBox(height: ds.space.s),
          SizedBox(
            height: 88,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: proposal.cloths.length,
              separatorBuilder: (_, _) => SizedBox(width: ds.space.xs),
              itemBuilder: (_, i) {
                final cloth = proposal.cloths[i];
                return SizedBox(
                  width: 68,
                  child: Column(
                    children: [
                      Expanded(
                        child: Container(
                          width: 68,
                          padding: EdgeInsets.all(ds.space.xs / 2),
                          decoration: BoxDecoration(
                            color: c.surfaceHigh,
                            borderRadius: ds.shape.smallRadius,
                          ),
                          child: cloth.thumbUrl.isEmpty
                              ? Icon(Icons.checkroom, color: c.textMuted)
                              : AppImage.path(
                                  cloth.thumbUrl,
                                  fit: BoxFit.contain,
                                ),
                        ),
                      ),
                      SizedBox(height: ds.space.xs / 2),
                      Text(
                        cloth.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ds.typo.mono.copyWith(
                          color: c.textMuted,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          SizedBox(height: ds.space.s),
          saved
              ? DsButton(
                  label: tr(context, 'stylist.openOutfit'),
                  icon: Icons.open_in_new,
                  kind: DsButtonKind.secondary,
                  expand: true,
                  onPressed: onOpen,
                )
              : DsButton(
                  label: tr(context, 'stylist.addToOutfits'),
                  icon: Icons.add,
                  expand: true,
                  loading: saving,
                  onPressed: saving ? null : onSave,
                ),
        ],
      ),
    );
  }
}

class _HistorySheet extends StatefulWidget {
  const _HistorySheet({required this.threads, required this.service});
  final List<StylistThread> threads;
  final StylistService service;

  @override
  State<_HistorySheet> createState() => _HistorySheetState();
}

class _HistorySheetState extends State<_HistorySheet> {
  late final List<StylistThread> _threads = [...widget.threads];

  Future<void> _delete(StylistThread t) async {
    try {
      await widget.service.deleteThread(t.id);
      if (mounted) setState(() => _threads.removeWhere((x) => x.id == t.id));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final c = ds.colors;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: EdgeInsets.fromLTRB(
          ds.space.gutter,
          0,
          ds.space.gutter,
          ds.space.l,
        ),
        children: [
          Text(
            tr(context, 'stylist.history').toUpperCase(),
            style: ds.typo.headline,
          ),
          SizedBox(height: ds.space.s),
          if (_threads.isEmpty)
            Text(
              tr(context, 'stylist.noHistory'),
              style: ds.typo.label.copyWith(color: c.textMuted),
            ),
          for (final t in _threads)
            DsInfoRow(
              icon: Icons.chat_bubble_outline,
              title: t.title.isEmpty ? '…' : t.title,
              detail: t.updatedAt.length >= 10
                  ? t.updatedAt.substring(0, 10)
                  : null,
              onTap: () => Navigator.pop(context, t.id),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: tr(context, 'agenda.remove'),
                onPressed: () => _delete(t),
              ),
            ),
        ],
      ),
    );
  }
}
