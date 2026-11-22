import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../l10n/app_text.dart';
import '../services/api_client.dart';

/// What to tell the user about [e], in their language.
///
/// - A transport failure (statusCode 0) becomes `error.network` or
///   `error.timeout`; the client's English wording never reaches the screen.
/// - Any other [ApiException] carries the server's own `detail`, shown as is.
/// - Anything else (a Dart exception, a plugin error) gets a generic text:
///   "Exception: ..." or a raw type name means nothing to the user.
String errorText(BuildContext context, Object e) {
  if (e is ApiException) {
    if (e.statusCode == 0) {
      return tr(
        context,
        e.kind == ApiErrorKind.timeout ? 'error.timeout' : 'error.network',
      );
    }
    return e.message.isEmpty ? tr(context, 'error.generic') : e.message;
  }
  if (e is TimeoutException) return tr(context, 'error.timeout');
  if (e is SocketException || e is HandshakeException) {
    return tr(context, 'error.network');
  }
  return tr(context, 'error.generic');
}

/// [errorText] behind an optional translated [prefixKey] ("Could not save").
///
/// When [e] has nothing specific to add (the generic text), the prefix alone
/// is clearer than "Could not save: Something went wrong".
String errorMessage(BuildContext context, Object e, {String? prefixKey}) {
  if (prefixKey == null) return errorText(context, e);
  final prefix = tr(context, prefixKey);
  final specific = e is ApiException || e is TimeoutException ||
      e is SocketException || e is HandshakeException;
  return specific ? '$prefix: ${errorText(context, e)}' : prefix;
}

/// Shows [message] in a snack bar. Does nothing once [context] is unmounted.
void showToast(BuildContext context, String message) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(message)));
}

/// Shows [e] as a snack bar, worded by [errorMessage].
void showErrorToast(BuildContext context, Object e, {String? prefixKey}) {
  if (!context.mounted) return;
  showToast(context, errorMessage(context, e, prefixKey: prefixKey));
}

/// The same toasts from inside a [State], guarded by `mounted`: screens call
/// these after an await without repeating the check at every call site.
extension StateToasts<T extends StatefulWidget> on State<T> {
  /// Shows [message] if this state is still mounted.
  void toast(String message) {
    if (mounted) showToast(context, message);
  }

  /// Shows the translation of [key] if this state is still mounted.
  void toastKey(String key, [Map<String, Object?>? params]) {
    if (mounted) showToast(context, tr(context, key, params));
  }

  /// Shows [e] (see [errorMessage]) if this state is still mounted.
  void toastError(Object e, {String? prefixKey}) {
    if (mounted) showErrorToast(context, e, prefixKey: prefixKey);
  }
}
