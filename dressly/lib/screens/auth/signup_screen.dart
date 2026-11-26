import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ds.dart';
import '../../l10n/app_text.dart';
import '../../services/auth_service.dart';
import '../../state/providers.dart';
import '../../widgets/error_toast.dart';

class SignupScreen extends ConsumerStatefulWidget {
  const SignupScreen({super.key});

  @override
  ConsumerState<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends ConsumerState<SignupScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _loading = false;
  String? _error;

  Future<void> _submit() async {
    if (_password.text.length < 6) {
      setState(() => _error = tr(context, 'auth.passwordTooShort'));
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await const AuthService().signup(
        _email.text.trim(),
        _password.text,
      );
      if (!mounted) return;
      ref.read(sessionProvider).setSession(result.user, result.token);
      // SignupScreen is a pushed route. After auth, pop it (and anything above)
      // so the home gate — which has now switched to the home shell — is shown.
      // Without this, the pushed SignupScreen sits on top and "nothing happens".
      Navigator.of(context).popUntil((r) => r.isFirst);
    } catch (e) {
      if (mounted) setState(() => _error = errorText(context, e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final gap = SizedBox(height: ds.space.s);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.all(ds.space.gutter),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: DsButton.icon(
                      icon: Icons.arrow_back,
                      semanticLabel: MaterialLocalizations.of(
                        context,
                      ).backButtonTooltip,
                      onPressed: () => Navigator.maybePop(context),
                    ),
                  ),
                  SizedBox(height: ds.space.m),
                  Text(
                    tr(context, 'auth.signup').toUpperCase(),
                    style: ds.typo.display,
                  ),
                  SizedBox(height: ds.space.l),
                  TextField(
                    controller: _email,
                    decoration: InputDecoration(
                      labelText: tr(context, 'auth.email'),
                    ),
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    autofillHints: const [AutofillHints.email],
                  ),
                  gap,
                  TextField(
                    controller: _password,
                    decoration: InputDecoration(
                      labelText: tr(context, 'auth.password'),
                    ),
                    obscureText: true,
                    onSubmitted: (_) => _loading ? null : _submit(),
                  ),
                  if (_error != null) ...[
                    gap,
                    Text(
                      _error!,
                      style: ds.typo.label.copyWith(color: ds.colors.danger),
                    ),
                  ],
                  SizedBox(height: ds.space.l),
                  DsButton(
                    label: tr(context, 'auth.createAccount'),
                    expand: true,
                    loading: _loading,
                    onPressed: _loading ? null : _submit,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
