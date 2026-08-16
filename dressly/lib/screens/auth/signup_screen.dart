import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_text.dart';
import '../../services/auth_service.dart';
import '../../state/session.dart';

class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key});

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
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
      final result =
          await const AuthService().signup(_email.text.trim(), _password.text);
      if (!mounted) return;
      context.read<Session>().setSession(result.user, result.token);
      // SignupScreen is a pushed route. After auth, pop it (and anything above)
      // so the home gate — which has now switched to CollectionScreen — is shown.
      // Without this, the pushed SignupScreen sits on top and "nothing happens".
      Navigator.of(context).popUntil((r) => r.isFirst);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'auth.signup'))),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _email,
                  decoration: InputDecoration(
                      border: const OutlineInputBorder(), labelText: tr(context, 'auth.email')),
                  keyboardType: TextInputType.emailAddress,
                  autocorrect: false,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  decoration: InputDecoration(
                      border: const OutlineInputBorder(), labelText: tr(context, 'auth.password')),
                  obscureText: true,
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!,
                      style: const TextStyle(color: Colors.redAccent)),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _loading ? null : _submit,
                  child: _loading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(tr(context, 'auth.createAccount')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}