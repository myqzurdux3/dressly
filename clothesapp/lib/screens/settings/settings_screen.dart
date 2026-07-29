import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_text.dart';
import '../../services/auth_service.dart';
import '../../state/gen_prefs_controller.dart';
import '../../state/locale_controller.dart';
import '../../state/session.dart';
import '../../state/theme_controller.dart';
import 'change_password_screen.dart';

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

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeController>();
    final locale = context.watch<LocaleController>();
    final genPrefs = context.watch<GenPrefsController>();
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'settings.title'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _SectionLabel(tr(context, 'settings.appearance')),
          const SizedBox(height: 8),
          Text(tr(context, 'settings.accentColor'),
              style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final c in ThemeController.presets)
                _ColorSwatch(
                  color: c,
                  selected: c.toARGB32() == theme.seed.toARGB32(),
                  onTap: () => context.read<ThemeController>().setSeed(c),
                ),
            ],
          ),
          const SizedBox(height: 24),
          Text(tr(context, 'settings.theme'),
              style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          SegmentedButton<ThemeMode>(
            segments: [
              ButtonSegment(
                  value: ThemeMode.light,
                  label: Text(tr(context, 'settings.themeLight')),
                  icon: const Icon(Icons.light_mode)),
              ButtonSegment(
                  value: ThemeMode.dark,
                  label: Text(tr(context, 'settings.themeDark')),
                  icon: const Icon(Icons.dark_mode)),
              ButtonSegment(
                  value: ThemeMode.system,
                  label: Text(tr(context, 'settings.themeSystem')),
                  icon: const Icon(Icons.brightness_auto)),
            ],
            selected: {theme.mode},
            onSelectionChanged: (s) =>
                context.read<ThemeController>().setMode(s.first),
          ),
          const SizedBox(height: 24),
          Text(tr(context, 'settings.language'),
              style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: locale.languageCode.isEmpty ? '' : locale.languageCode,
            isExpanded: true,
            decoration: const InputDecoration(border: OutlineInputBorder()),
            items: [
              DropdownMenuItem(
                  value: '', child: Text(tr(context, 'settings.languageSystem'))),
              ...LocaleController.languages.entries.map(
                (e) => DropdownMenuItem(value: e.key, child: Text(e.value)),
              ),
            ],
            onChanged: (v) => context
                .read<LocaleController>()
                .setLanguage((v == null || v.isEmpty) ? null : v),
          ),
          const Divider(height: 40),
          _SectionLabel(tr(context, 'settings.generation')),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: genPrefs.highQualityOnly,
            onChanged: (v) =>
                context.read<GenPrefsController>().setHighQualityOnly(v),
            title: Text(tr(context, 'settings.hqOnly')),
            subtitle: Text(tr(context, 'settings.hqOnlyHint')),
          ),
          const Divider(height: 40),
          _SectionLabel(tr(context, 'settings.account')),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.lock_outline),
            title: Text(tr(context, 'settings.changePassword')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ChangePasswordScreen()),
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.logout, color: Colors.redAccent),
            title: Text(tr(context, 'settings.logout'),
                style: const TextStyle(color: Colors.redAccent)),
            onTap: () => _logout(context),
          ),
          const Divider(height: 40),
          _SectionLabel(tr(context, 'settings.credits')),
          const SizedBox(height: 8),
          const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.checkroom),
            title: Text('Dressly'),
            subtitle: Text('Version 1.0.0'),
          ),
          const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.favorite_outline),
            // TODO: replace with your real name/handle.
            title: Text('Made by Alex Martin'),
            subtitle: Text('© 2026'),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text.toUpperCase(),
        style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            letterSpacing: 1,
            color: Colors.grey),
      );
}

class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({
    required this.color,
    required this.selected,
    required this.onTap,
  });
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? Colors.white : Colors.white24,
            width: selected ? 3 : 1,
          ),
        ),
        child: selected
            ? const Icon(Icons.check, color: Colors.white, size: 22)
            : null,
      ),
    );
  }
}
