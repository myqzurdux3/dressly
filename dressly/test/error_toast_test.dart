import 'dart:async';
import 'dart:io';

import 'package:dressly/services/api_client.dart';
import 'package:dressly/widgets/error_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

const _delegates = <LocalizationsDelegate<dynamic>>[
  GlobalMaterialLocalizations.delegate,
  GlobalWidgetsLocalizations.delegate,
  GlobalCupertinoLocalizations.delegate,
];

/// Pumps a page at [locale] and hands back a context inside it.
Future<BuildContext> _context(WidgetTester tester, String locale) async {
  late BuildContext ctx;
  await tester.pumpWidget(MaterialApp(
    locale: Locale(locale),
    supportedLocales: const [Locale('en'), Locale('fr')],
    localizationsDelegates: _delegates,
    home: Scaffold(
      body: Builder(builder: (c) {
        ctx = c;
        return const SizedBox();
      }),
    ),
  ));
  return ctx;
}

void main() {
  group('errorText', () {
    testWidgets('transport failures are translated, network vs timeout',
        (tester) async {
      final fr = await _context(tester, 'fr');
      expect(
        errorText(fr, ApiException(0, 'x', kind: ApiErrorKind.network)),
        startsWith('Impossible de joindre le serveur'),
      );
      expect(
        errorText(fr, ApiException(0, 'x', kind: ApiErrorKind.timeout)),
        startsWith('Le serveur n\'a pas répondu à temps'),
      );
      // A status-0 error without a kind still reads as a network failure.
      expect(errorText(fr, ApiException(0, 'x')),
          startsWith('Impossible de joindre'));
    });

    testWidgets('the client maps real transport errors to the right kind',
        (tester) async {
      final en = await _context(tester, 'en');
      final timeout =
          ApiClient.friendly(TimeoutException('t')) as ApiException;
      final socket =
          ApiClient.friendly(const SocketException('s')) as ApiException;
      expect(timeout.kind, ApiErrorKind.timeout);
      expect(socket.kind, ApiErrorKind.network);
      expect(errorText(en, timeout), startsWith('The server did not answer'));
      expect(errorText(en, socket), startsWith('Could not reach the server'));
    });

    testWidgets('server errors keep the server wording', (tester) async {
      final fr = await _context(tester, 'fr');
      expect(errorText(fr, ApiException(400, 'Name is required')),
          'Name is required');
    });

    testWidgets('any other exception gets a generic text, never a Dart dump',
        (tester) async {
      final fr = await _context(tester, 'fr');
      for (final e in <Object>[
        Exception('boom'),
        StateError('bad state'),
        const FormatException('bad'),
        'just a string',
      ]) {
        final text = errorText(fr, e);
        expect(text, 'Une erreur est survenue. Veuillez réessayer.');
        expect(text, isNot(contains('Exception')));
        expect(text, isNot(contains('Error')));
      }
    });
  });

  group('errorMessage', () {
    testWidgets('a prefix goes before a specific error', (tester) async {
      final en = await _context(tester, 'en');
      expect(
        errorMessage(en, ApiException(409, 'Already exists'),
            prefixKey: 'form.saveFailed'),
        endsWith(': Already exists'),
      );
    });

    testWidgets('a prefix stands alone over a generic error', (tester) async {
      final en = await _context(tester, 'en');
      final prefixOnly =
          errorMessage(en, Exception('x'), prefixKey: 'form.saveFailed');
      expect(prefixOnly, isNot(contains(':')));
      expect(prefixOnly, isNot(contains('Exception')));
    });
  });

  testWidgets('showErrorToast puts the text in a snack bar', (tester) async {
    final en = await _context(tester, 'en');
    showErrorToast(en, ApiException(0, 'x', kind: ApiErrorKind.timeout));
    await tester.pump();
    expect(find.textContaining('The server did not answer in time'),
        findsOneWidget);
  });
}
