import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../design/ds.dart';
import '../../l10n/app_text.dart';
import '../../services/auth_service.dart';
import '../../state/session.dart';

/// Change the signed-in user's password.
///
/// The current password is asked for even though the user is already signed in:
/// a token is enough to browse, but it should not be enough to lock the owner
/// out of their own account.
class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({super.key});

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _form = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  bool _show = false;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_form.currentState?.validate() ?? false) || _busy) return;
    setState(() => _busy = true);

    final session = context.read<Session>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      final result = await const AuthService().changePassword(
        session.token!,
        currentPassword: _current.text,
        newPassword: _next.text,
      );
      // The server ended every session opened before the change, including this
      // one, and returned a replacement. Adopt it or the next request 401s.
      session.setSession(result.user, result.token);
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(tr(context, 'password.changed'))),
      );
      navigator.pop();
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? _required(String? v) =>
      (v == null || v.isEmpty) ? tr(context, 'password.required') : null;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final gap = SizedBox(height: ds.space.m);
    return Form(
      key: _form,
      child: DsSubPage(
        title: tr(context, 'password.title'),
        bottom: DsButton(
          label: tr(context, 'password.submit'),
          expand: true,
          loading: _busy,
          onPressed: _busy ? null : _submit,
        ),
        children: [
          TextFormField(
            controller: _current,
            obscureText: !_show,
            autofillHints: const [AutofillHints.password],
            decoration: InputDecoration(
              labelText: tr(context, 'password.current'),
            ),
            validator: _required,
          ),
          gap,
          TextFormField(
            controller: _next,
            obscureText: !_show,
            autofillHints: const [AutofillHints.newPassword],
            decoration: InputDecoration(labelText: tr(context, 'password.new')),
            validator: (v) {
              if (v == null || v.length < 6) {
                return tr(context, 'auth.passwordTooShort');
              }
              if (v == _current.text) {
                return tr(context, 'password.mustDiffer');
              }
              return null;
            },
          ),
          gap,
          TextFormField(
            controller: _confirm,
            obscureText: !_show,
            decoration: InputDecoration(
              labelText: tr(context, 'password.confirm'),
            ),
            // Checked here rather than server-side: mistyping a new password
            // twice would otherwise lock the account behind a value nobody
            // knows.
            validator: (v) =>
                v == _next.text ? null : tr(context, 'password.mismatch'),
            onFieldSubmitted: (_) => _submit(),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _show,
            onChanged: (v) => setState(() => _show = v),
            title: Text(tr(context, 'password.show'), style: ds.typo.body),
          ),
          Text(
            tr(context, 'password.signsOutOthers'),
            style: ds.typo.label.copyWith(color: ds.colors.textMuted),
          ),
        ],
      ),
    );
  }
}
