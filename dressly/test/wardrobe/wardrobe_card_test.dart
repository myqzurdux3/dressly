import 'package:dressly/models/cloth.dart';
import 'package:dressly/screens/wardrobe/wardrobe_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/ds_harness.dart';

ClothImage _img(String role, String thumb, {String bg = 'accepted'}) =>
    ClothImage(
      id: role.hashCode,
      role: role,
      sortOrder: 0,
      bgAccepted: bg,
      originalUrl: '/o/$thumb',
      cutoutUrl: '/c/$thumb',
      thumbUrl: thumb,
    );

Cloth _cloth({
  List<ClothColor> colors = const [],
  List<ClothImage>? images,
  int score = 0,
  String brand = 'NIKE',
  bool favorite = false,
}) => Cloth(
  id: 7,
  userId: 1,
  name: 'Hoodie gris',
  brand: brand,
  cut: 'normal',
  category: 'hoodie',
  customTags: const [],
  colors: colors,
  images: images ?? [_img('front', 'front.jpg'), _img('back', 'back.jpg')],
  score: score,
  isFavorite: favorite,
);

Widget _placeholder(String path, int memWidth) =>
    const SizedBox.expand(child: ColoredBox(color: Color(0x33000000)));

void main() {
  setUpAll(loadDsFonts);

  test('swatchColorOf prefers full, then first, then empty', () {
    expect(
      swatchColorOf(
        _cloth(
          colors: [
            ClothColor(color: 'Red', dominance: 'little'),
            ClothColor(color: 'Grey', dominance: 'full'),
          ],
        ),
      ),
      'Grey',
    );
    expect(
      swatchColorOf(
        _cloth(
          colors: [ClothColor(color: 'Red', dominance: 'part')],
        ),
      ),
      'Red',
    );
    expect(swatchColorOf(_cloth()), '');
  });

  testWidgets('review badge shows when an image is pending', (t) async {
    await t.pumpWidget(
      dsFrame(
        WardrobeCard(
          cloth: _cloth(images: [_img('front', 'f.jpg', bg: 'pending')]),
          onTap: () {},
          imageBuilder: _placeholder,
        ),
      ),
    );
    expect(find.text('REVIEW'), findsOneWidget);
  });

  testWidgets('subtitle shows brand and rating', (t) async {
    await t.pumpWidget(
      dsFrame(
        WardrobeCard(
          cloth: _cloth(score: 4),
          onTap: () {},
          imageBuilder: _placeholder,
        ),
      ),
    );
    expect(find.text('NIKE · 4/5'), findsOneWidget);
  });

  testWidgets('heart calls onToggleFavorite', (t) async {
    var n = 0;
    await t.pumpWidget(
      dsFrame(
        WardrobeCard(
          cloth: _cloth(),
          onTap: () {},
          onToggleFavorite: () => n++,
          imageBuilder: _placeholder,
        ),
      ),
    );
    await t.tap(find.bySemanticsLabel('Favorite clothes'));
    expect(n, 1);
  });

  testWidgets('tapping the back thumbnail swaps the main image path', (
    t,
  ) async {
    final paths = <String>[];
    Widget rec(String p, int w) {
      if (w > 100) paths.add(p);
      return const SizedBox.expand();
    }

    await t.pumpWidget(
      dsFrame(WardrobeCard(cloth: _cloth(), onTap: () {}, imageBuilder: rec)),
    );
    await t.tap(find.bySemanticsLabel('Show back'));
    await t.pump();
    expect(paths.first, 'front.jpg');
    expect(paths.last, 'back.jpg');
  });

  testWidgets('golden', (t) async {
    await expectDsGolden(
      t,
      SizedBox(
        width: 190,
        height: 190 / WardrobeCard.aspectRatio,
        child: WardrobeCard(
          cloth: _cloth(
            colors: [ClothColor(color: 'Grey', dominance: 'full')],
            score: 4,
            favorite: true,
          ),
          onTap: () {},
          imageBuilder: _placeholder,
        ),
      ),
      'wardrobe_card',
      height: 260,
    );
  });
}
