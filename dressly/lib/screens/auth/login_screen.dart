import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_text.dart';
import '../../services/auth_service.dart';
import '../../state/session.dart';
import '../../widgets/brand_logo.dart';
import 'signup_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
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
      final result =
          await const AuthService().login(_email.text.trim(), _password.text);
      if (!mounted) return;
      context.read<Session>().setSession(result.user, result.token);
      // LoginScreen is the home route, but popUntil(isFirst) is a safe no-op
      // here and keeps this logic identical to SignupScreen (which IS pushed
      // and must be popped to reveal the now-Collection home).
      Navigator.of(context).popUntil((r) => r.isFirst);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Center(
                  child: DresslyLockup(tileSize: 84, wordmarkSize: 44),
                ),
                const SizedBox(height: 32),
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
                      : Text(tr(context, 'auth.signin')),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _loading
                      ? null
                      : () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const SignupScreen()),
                          ),
                  child: Text(tr(context, 'auth.noAccount')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}