import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ds.dart';
import '../../l10n/app_text.dart';
import '../../services/auth_service.dart';
import '../../state/providers.dart';
import '../../widgets/brand_logo.dart';
import 'signup_screen.dart';
import '../../widgets/error_toast.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _loading = false;
  String? _error;

  Future<void> _submit() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await const AuthService().login(
        _email.text.trim(),
        _password.text,
      );
      if (!mounted) return;
      ref.read(sessionProvider).setSession(result.user, result.token);
      // LoginScreen is the home route, but popUntil(isFirst) is a safe no-op
      // here and keeps this logic identical to SignupScreen (which IS pushed
      // and must be popped to reveal the now-Collection home).
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
                  const Center(child: DresslyLockup()),
                  SizedBox(height: ds.space.xl),
                  TextField(
                    controller: _email,
                    decoration: InputDecoration(
                      labelText: tr(context, 'auth.emailOrUsername'),
                    ),
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    autofillHints: const [
                      AutofillHints.username,
                      AutofillHints.email,
                    ],
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
                    label: tr(context, 'auth.signin'),
                    expand: true,
                    loading: _loading,
                    onPressed: _loading ? null : _submit,
                  ),
                  gap,
                  DsButton(
                    label: tr(context, 'auth.noAccount'),
                    kind: DsButtonKind.secondary,
                    expand: true,
                    onPressed: _loading
                        ? null
                        : () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const SignupScreen(),
                            ),
                          ),
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
