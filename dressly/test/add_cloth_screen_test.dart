import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:dressly/screens/cloth/add_cloth_screen.dart';
import 'package:dressly/screens/cloth/cloth_detail_screen.dart';
import 'package:dressly/services/pinned_http.dart';
import 'package:dressly/state/session.dart';
import 'package:dressly/models/user.dart';
import 'package:dressly/widgets/image_slot.dart';

/// Adding a garment, end to end through the widget tree: pick two photos, name
/// it, choose a category, save.
///
/// The screen is 960 lines and every path through it ends in a multipart POST
/// that cannot be undone from the app. What is asserted here is what the user
/// sees (the tile appears, the refusal is explained) and what leaves the phone
/// (the exact fields and the two files).

/// A real 1x1 PNG. Image.file decodes what it is given, so a placeholder made
/// of arbitrary bytes would throw inside the tile rather than draw one.
final _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmM'
    'IQAAAABJRU5ErkJggg==');

/// The gallery, replaced. The real one opens a platform dialog, which a widget
/// test has no way to answer.
class _FakeGallery extends FilePicker {
  _FakeGallery(this.paths);

  final List<String> paths;
  int calls = 0;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    if (calls >= paths.length) return null; // cancelled
    final path = paths[calls++];
    return FilePickerResult(
        [PlatformFile(path: path, name: path.split('/').last, size: 1)]);
  }
}

Map<String, dynamic> _cloth({List<Map<String, dynamic>> images = const []}) => {
      'id': 7,
      'user_id': 1,
      'name': 'Blue tee',
      'brand': 'UNIQLO',
      'cut': 'normal',
      'category': 'tshirt',
      'custom_tags': <String>[],
      'colors': <Map<String, dynamic>>[],
      'score': 0,
      'images': images,
    };

/// Reads one form field back out of an encoded multipart body.
String _part(String body, String field) {
  final match = RegExp('name="$field"\r\n\r\n(.*?)\r\n', dotAll: true)
      .firstMatch(body);
  return match == null ? '' : match.group(1)!;
}

void main() {
  late Directory tmp;
  late List<String> picked;
  final requests = <http.BaseRequest>[];
  final bodies = <String>[];

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('dressly_form');
    picked = [
      for (final name in ['front.png', 'back.png', 'extra.png'])
        (File('${tmp.path}/$name')..writeAsBytesSync(_png)).path,
    ];
    FilePicker.platform = _FakeGallery(picked);
    requests.clear();
    bodies.clear();
    PinnedHttp.setClientForTesting(MockClient((req) async {
      requests.add(req);
      final path = req.url.path;
      if (path.contains('/autocomplete/')) return http.Response('[]', 200);
      if (req.method == 'POST' && path.endsWith('/clothes')) {
        // MockClient hands the handler a plain Request: the multipart body
        // arrives already encoded, which is what actually goes over the wire.
        // allowMalformed: the body carries raw PNG bytes between the field
        // parts, which are not valid UTF-8.
        bodies.add(utf8.decode(req.bodyBytes, allowMalformed: true));
        return http.Response(jsonEncode(_cloth()), 200);
      }
      return http.Response(jsonEncode(_cloth()), 200);
    }));
  });

  tearDown(() async {
    PinnedHttp.setClientForTesting(null);
    await tmp.delete(recursive: true);
  });

  Future<void> pump(WidgetTester tester) async {
    final session = Session()
      ..setSession(
          AppUser(id: 1, email: 'a@b.co', isAdmin: false), 'tok');
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: session,
      child: const MaterialApp(
        locale: Locale('en'),
        home: ClothFormScreen(),
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// Fills the form's required text fields and picks the category.
  Future<void> fillMetadata(WidgetTester tester,
      {String name = 'Blue tee'}) async {
    await tester.enterText(find.byType(TextField).first, name);
    await tester.ensureVisible(find.byType(DropdownButtonFormField<String>));
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('T-shirt').last);
    await tester.pumpAndSettle();
  }

  /// The save button sits below the fold on a test-sized screen.
  ///
  /// Deliberately pumped by hand rather than with pumpAndSettle: the screen
  /// this lands on shows a CircularProgressIndicator while it loads, which
  /// never stops animating, so settling would wait forever.
  Future<void> save(WidgetTester tester) async {
    final button = find.widgetWithText(FilledButton, 'Save');
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    // The upload reads the two picked files off the real filesystem, and real
    // I/O only makes progress inside runAsync — a plain pump loop leaves the
    // request forever half-sent.
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// Taps "add a picture", then "gallery" in the sheet that opens.
  Future<void> addPhoto(WidgetTester tester) async {
    await tester.tap(find.byType(OutlinedButton).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose from gallery / files'));
    await tester.pumpAndSettle();
  }

  testWidgets('each picked photo becomes a tile', (tester) async {
    await pump(tester);
    expect(find.byType(ImageSlot), findsNothing);

    await addPhoto(tester);
    expect(find.byType(ImageSlot), findsOneWidget);
    await addPhoto(tester);
    expect(find.byType(ImageSlot), findsNWidgets(2));
  });

  testWidgets('one photo is not enough, and saying so costs no request',
      (tester) async {
    await pump(tester);
    await addPhoto(tester);
    await fillMetadata(tester); // everything else valid, so pictures decide
    await save(tester);

    // Asserted on the SnackBar, not on any text: the same sentence also sits
    // permanently under the "Pictures" heading as a hint, so find.text alone
    // passes whether the refusal happened or not.
    expect(
        find.descendant(
            of: find.byType(SnackBar),
            matching: find.textContaining('Front and back')),
        findsOneWidget);
    expect(requests.where((r) => r.method == 'POST'), isEmpty,
        reason: 'nothing may be uploaded before the form is complete');
  });

  testWidgets('two photos, a name and a category upload once', (tester) async {
    await pump(tester);
    await addPhoto(tester);
    await addPhoto(tester);
    await fillMetadata(tester);
    await save(tester);

    final posts = requests.where((r) => r.method == 'POST').toList();
    expect(posts, hasLength(1), reason: 'one garment, one POST');

    final sent = bodies.single;
    expect(_part(sent, 'name'), 'Blue tee');
    expect(_part(sent, 'category'), 'tshirt');
    // Both photos leave, under the field name the backend reads them from.
    expect('filename='.allMatches(sent), hasLength(2));
    expect('name="images"'.allMatches(sent), hasLength(2));

    // The user lands on the new garment, not back on an empty form.
    // Two more frames for the route transition, which the loop above starts
    // but does not finish.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(ClothDetailScreen), findsOneWidget);
    expect(find.byType(ClothFormScreen), findsNothing);
  });

  testWidgets('a rejected upload leaves the form filled in', (tester) async {
    PinnedHttp.setClientForTesting(MockClient((req) async {
      requests.add(req);
      if (req.url.path.contains('/autocomplete/')) {
        return http.Response('[]', 200);
      }
      return http.Response(jsonEncode({'detail': 'File too large'}), 413);
    }));
    await pump(tester);
    await addPhoto(tester);
    await addPhoto(tester);
    await fillMetadata(tester);
    await save(tester);

    // Still here, still holding the two photos and the name: a failed upload
    // that dropped the form would mean re-taking both pictures.
    expect(find.byType(ClothFormScreen), findsOneWidget);
    expect(find.byType(ImageSlot), findsNWidgets(2));
    expect(find.text('Blue tee'), findsOneWidget);
    expect(find.textContaining('Save failed'), findsOneWidget);
  });
}
