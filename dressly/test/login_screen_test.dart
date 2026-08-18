import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dressly/screens/auth/login_screen.dart';
import 'package:dressly/services/pinned_http.dart';
import 'package:dressly/state/session.dart';

/// The login screen, driven the way a person drives it: type, tap, look.
///
/// This is the screen with the least room for a silent failure — it is the only
/// one every session starts on, and a mistake here locks the app entirely. The
/// three behaviours below are the ones that were only ever verified by hand.
///
/// No socket is opened: [PinnedHttp.setClientForTesting] replaces the client
/// that AuthService reaches through.

/// A dummy account payload shaped like the server's, so AppUser.fromJson is
/// exercised rather than bypassed.
const _user = {
  'id': 1,
  'email': 'a@b.co',
  'is_admin': false,
  'created_at': '2026-08-18T10:00:00',
};

Widget _app(Session session) => ChangeNotifierProvider.value(
      value: session,
      child: MaterialApp(
        locale: const Locale('en'),
        // The gate the real app uses, reduced to what this test can assert on:
        // the login screen must be replaced once the session holds a token.
        home: Consumer<Session>(
          builder: (_, s, _) =>
              s.isLoggedIn ? const Text('HOME') : const LoginScreen(),
        ),
      ),
    );

Future<void> _fillIn(WidgetTester tester,
    {String email = 'a@b.co', String password = 'hunter22'}) async {
  await tester.enterText(find.widgetWithText(TextField, 'Email'), email);
  await tester.enterText(find.widgetWithText(TextField, 'Password'), password);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => PinnedHttp.setClientForTesting(null));

  testWidgets('a rejected password shows the server message, and stays put',
      (tester) async {
    PinnedHttp.setClientForTesting(MockClient((_) async => http.Response(
        jsonEncode({'detail': 'Incorrect email or password'}), 401)));
    final session = Session();

    await tester.pumpWidget(_app(session));
    await _fillIn(tester, password: 'wrong-one');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();

    // The server's own wording, not a generic failure: a user who mistypes
    // their address and one who mistypes their password must not be told the
    // same thing by accident.
    expect(find.textContaining('Incorrect email or password'), findsOneWidget);
    expect(session.isLoggedIn, isFalse);
    expect(find.text('HOME'), findsNothing);
    // Still usable — the button came back out of its loading state.
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull);
  });

  testWidgets('a good password opens the session and leaves the screen',
      (tester) async {
    late String body;
    PinnedHttp.setClientForTesting(MockClient((req) async {
      body = req.body;
      return http.Response(
          jsonEncode({'token': 'tok-123', 'user': _user}), 200);
    }));
    final session = Session();

    await tester.pumpWidget(_app(session));
    await _fillIn(tester, email: '  a@b.co  ');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();

    expect(session.token, 'tok-123');
    expect(session.user!.email, 'a@b.co');
    expect(find.text('HOME'), findsOneWidget);
    expect(find.byType(LoginScreen), findsNothing);
    // The address is trimmed before it is sent. Leading whitespace from a
    // password manager's paste would otherwise be a login that fails forever
    // with correct credentials.
    expect(jsonDecode(body)['email'], 'a@b.co');
    // The token is persisted, which is what restores the session on next start.
    expect((await SharedPreferences.getInstance()).getString('auth_token'),
        'tok-123');
  });

  testWidgets('while the request is in flight the button cannot fire twice',
      (tester) async {
    var calls = 0;
    final answer = Completer<http.Response>();
    PinnedHttp.setClientForTesting(MockClient((_) {
      calls++;
      return answer.future;
    }));

    await tester.pumpWidget(_app(Session()));
    await _fillIn(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pump(); // the request is out, the answer is not back

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull, reason: 'a second tap would post the login twice');
    // Tapping anyway must do nothing at all.
    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    expect(calls, 1);

    answer.complete(
        http.Response(jsonEncode({'token': 't', 'user': _user}), 200));
    await tester.pumpAndSettle();
    expect(find.text('HOME'), findsOneWidget);
  });
}
