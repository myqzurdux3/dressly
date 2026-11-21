import 'package:flutter/material.dart';

import '../../app.dart';
import '../../design/ds.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_text.dart';
import '../../services/auth_service.dart';
import '../../state/gen_prefs_controller.dart';
import '../../state/locale_controller.dart';
import '../../state/session.dart';
import '../../state/theme_controller.dart';
import 'change_password_screen.dart';
import 'api_credits_screen.dart';
import 'weather_location_screen.dart';

/// Appearance customization + account. Keeps "Sign out" here, away from the
/// Models management (which lives on the Create screen).
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  Future<void> _logout(BuildContext context) async {
    await const AuthService().clearToken();
    if (!context.mounted) return;
    // Pop back to the shell first, then flip the session so the auth gate
    // rebuilds the login screen at the root.
    Navigator.of(context).popUntil((r) => r.isFirst);
    context.read<Session>().logout();
  }

  String _usernameDetail(BuildContext context) {
    final name = context.watch<Session>().user?.username ?? '';
    return name.isEmpty ? tr(context, 'settings.usernameNone') : name;
  }

  /// Ask for a new user name and save it. Empty clears it.
  Future<void> _editUsername(BuildContext context) async {
    final session = context.read<Session>();
    final messenger = ScaffoldMessenger.of(context);
    final savedText = tr(context, 'settings.usernameSaved');
    final field = TextEditingController(text: session.user?.username ?? '');
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr(ctx, 'settings.username')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: field,
              autofocus: true,
              autocorrect: false,
              decoration: InputDecoration(
                hintText: tr(ctx, 'settings.usernameHint'),
              ),
              onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
            ),
            SizedBox(height: ctx.ds.space.xs),
            Text(
              tr(ctx, 'settings.usernameRules'),
              style: ctx.ds.typo.label.copyWith(color: ctx.ds.colors.textMuted),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr(ctx, 'common.cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, field.text.trim()),
            child: Text(tr(ctx, 'common.save')),
          ),
        ],
      ),
    );
    field.dispose();
    final token = session.token;
    if (picked == null || token == null) return;
    try {
      final user = await const AuthService().changeUsername(token, picked);
      session.setSession(user, token);
      messenger.showSnackBar(SnackBar(content: Text(savedText)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeController>();
    final locale = context.watch<LocaleController>();
    final genPrefs = context.watch<GenPrefsController>();
    final ds = context.ds;
    final c = ds.colors;
    final muted = ds.typo.label.copyWith(color: c.textMuted);
    void push(Widget page) =>
        Navigator.push(context, MaterialPageRoute(builder: (_) => page));
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.only(bottom: ds.space.xl),
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                ds.space.gutter,
                ds.space.s,
                ds.space.gutter,
                0,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: DsButton.icon(
                  icon: Icons.arrow_back,
                  semanticLabel: MaterialLocalizations.of(
                    context,
                  ).backButtonTooltip,
                  onPressed: () => Navigator.maybePop(context),
                ),
              ),
            ),
            DsHeader(
              line1: tr(context, 'settings.title1'),
              line2: tr(context, 'settings.title2'),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: ds.space.gutter),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DsSectionTitle(tr(context, 'settings.accentColor')),
                  Wrap(
                    spacing: ds.space.s,
                    runSpacing: ds.space.s,
                    children: [
                      for (final a in DsAccent.values)
                        _ColorSwatch(
                          key: ValueKey('accent-${a.name}'),
                          color: a.base,
                          label: tr(context, 'accent.${a.name}'),
                          selected: a == theme.accent,
                          onTap: () =>
                              context.read<ThemeController>().setAccent(a),
                        ),
                    ],
                  ),
                  DsSectionTitle(tr(context, 'settings.theme')),
                  DsSegment<ThemeMode>(
                    options: [
                      (ThemeMode.light, tr(context, 'settings.themeLight')),
                      (ThemeMode.dark, tr(context, 'settings.themeDark')),
                      (ThemeMode.system, tr(context, 'settings.themeSystem')),
                    ],
                    value: theme.mode,
                    onChanged: (m) =>
                        context.read<ThemeController>().setMode(m),
                  ),
                  DsSectionTitle(tr(context, 'settings.language')),
                  Wrap(
                    spacing: ds.space.xs,
                    runSpacing: ds.space.xs,
                    children: [
                      for (final (code, name) in [
                        ('', tr(context, 'settings.languageSystem')),
                        for (final e in LocaleController.languages.entries)
                          (e.key, e.value),
                      ])
                        DsChip(
                          label: name,
                          selected: locale.languageCode == code,
                          onTap: () => context
                              .read<LocaleController>()
                              .setLanguage(code.isEmpty ? null : code),
                        ),
                    ],
                  ),
                  DsSectionTitle(tr(context, 'settings.generation')),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: genPrefs.highQualityOnly,
                    onChanged: (v) => context
                        .read<GenPrefsController>()
                        .setHighQualityOnly(v),
                    title: Text(
                      tr(context, 'settings.hqOnly'),
                      style: ds.typo.bodyStrong,
                    ),
                    subtitle: Text(
                      tr(context, 'settings.hqOnlyHint'),
                      style: muted,
                    ),
                  ),
                  const _OpenRouterSwitch(),
                  DsInfoRow(
                    icon: Icons.wb_sunny_outlined,
                    title: tr(context, 'settings.weatherPlace'),
                    detail: tr(context, 'settings.weatherPlaceHint'),
                    onTap: () => push(const WeatherLocationScreen()),
                  ),
                  // Admin-only, and hidden rather than disabled: a screen you
                  // cannot open is noise on everybody else's settings page.
                  if (context.watch<Session>().user?.isAdmin == true) ...[
                    DsSectionTitle(tr(context, 'settings.admin')),
                    DsInfoRow(
                      icon: Icons.account_balance_wallet_outlined,
                      title: tr(context, 'settings.apiCredits'),
                      detail: tr(context, 'settings.apiCreditsHint'),
                      onTap: () => push(const ApiCreditsScreen()),
                    ),
                  ],
                  DsSectionTitle(tr(context, 'settings.account')),
                  DsInfoRow(
                    icon: Icons.alternate_email,
                    title: tr(context, 'settings.username'),
                    detail: _usernameDetail(context),
                    onTap: () => _editUsername(context),
                  ),
                  DsInfoRow(
                    icon: Icons.lock_outline,
                    title: tr(context, 'settings.changePassword'),
                    onTap: () => push(const ChangePasswordScreen()),
                  ),
                  DsInfoRow(
                    icon: Icons.logout,
                    title: tr(context, 'settings.logout'),
                    danger: true,
                    onTap: () => _logout(context),
                  ),
                  SizedBox(height: ds.space.xl),
                  Text(
                    'DRESSLY · VERSION 1.0.0 · © 2026',
                    textAlign: TextAlign.center,
                    style: ds.typo.monoSmall.copyWith(color: c.textMuted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Use OpenRouter" — offered only when the server has a key for it.
class _OpenRouterSwitch extends StatefulWidget {
  const _OpenRouterSwitch();

  @override
  State<_OpenRouterSwitch> createState() => _OpenRouterSwitchState();
}

class _OpenRouterSwitchState extends State<_OpenRouterSwitch> {
  late final Future<({bool available, String model})> _info = outfitsServiceOf(
    context,
  ).openRouterInfo();

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final prefs = context.watch<GenPrefsController>();
    final muted = ds.typo.label.copyWith(color: ds.colors.textMuted);
    return FutureBuilder<({bool available, String model})>(
      future: _info,
      builder: (context, snap) {
        final info = snap.data;
        final available = info?.available ?? false;
        return SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: available && prefs.useOpenRouter,
          onChanged: available
              ? (v) => context.read<GenPrefsController>().setUseOpenRouter(v)
              : null,
          title: Text(
            tr(context, 'settings.openRouter'),
            style: ds.typo.bodyStrong,
          ),
          subtitle: Text(
            snap.hasError
                ? tr(context, 'settings.openRouterOff')
                : info == null
                ? tr(context, 'settings.openRouterChecking')
                : available
                ? tr(context, 'settings.openRouterHint', {'model': info.model})
                : tr(context, 'settings.openRouterOff'),
            style: muted,
          ),
        );
      },
    );
  }
}

class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({
    super.key,
    required this.color,
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final Color color;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.ds.colors;
    return Semantics(
      label: label,
      selected: selected,
      button: true,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? c.text : c.hairline,
              width: selected ? 3 : 1,
            ),
          ),
          child: selected
              ? Icon(Icons.check, color: c.onAccent, size: 22)
              : null,
        ),
      ),
    );
  }
}
