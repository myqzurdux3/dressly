import 'package:clothesapp/models/agenda.dart';
import 'package:clothesapp/models/cloth.dart';
import 'package:clothesapp/models/outfit.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ClothImage.enhanceDescribe', () {
    // The switch that decides whether the owner's own words about a garment go
    // into the AI prompt. Remembered per image, so a retry repeats the job.
    test('an image nobody has chosen for describes', () {
      final im = ClothImage.fromJson({
        'id': 1, 'role': 'front', 'original_url': '', 'cutout_url': '',
      });
      expect(im.enhanceDescribe, isTrue);
    });

    test('an explicit false is read as false', () {
      final im = ClothImage.fromJson({
        'id': 1, 'role': 'front', 'original_url': '', 'cutout_url': '',
        'enhance_describe': false,
      });
      expect(im.enhanceDescribe, isFalse);
    });

    test('copyWith flips it and keeps everything else', () {
      final im = ClothImage.fromJson({
        'id': 7, 'role': 'back', 'original_url': 'o', 'cutout_url': 'c',
        'enhance_status': 'failed', 'enhance_error': 'declined',
        'enhance_tier': 'flex',
      });
      final off = im.copyWith(enhanceDescribe: false);
      expect(off.enhanceDescribe, isFalse);
      expect(off.id, 7);
      expect(off.role, 'back');
      expect(off.enhanceStatus, 'failed');
      expect(off.enhanceError, 'declined');
      expect(off.enhanceTier, 'flex');
    });
  });


  _cutoutStatusTests();
  _enhancedPreviewTests();
  group('Cloth.fromJson', () {
    test('parses fields incl. last_worn_at and images', () {
      final c = Cloth.fromJson({
        'id': 1,
        'user_id': 7,
        'name': 'Tee',
        'brand': 'Acme',
        'cut': 'slim',
        'category': 'tshirt',
        'custom_tags': ['a', 'b'],
        'score': 4,
        'last_worn_at': '2026-01-02',
        'colors': [
          {'id': 1, 'color': 'Red', 'dominance': 'full'}
        ],
        'images': [
          {
            'id': 10,
            'role': 'front',
            'sort_order': 0,
            'bg_accepted': 'accepted',
            'original_url': '/images/1/front.png',
            'cutout_url': '/images/1/front_cutout.png',
          }
        ],
      });
      expect(c.id, 1);
      expect(c.lastWornAt, '2026-01-02');
      expect(c.score, 4);
      expect(c.customTags, ['a', 'b']);
      expect(c.displayImageUrl, '/images/1/front_cutout.png');
    });

    test('rejected image falls back to original for display', () {
      final img = ClothImage.fromJson({
        'id': 1,
        'role': 'front',
        'sort_order': 0,
        'bg_accepted': 'rejected',
        'original_url': '/o.png',
        'cutout_url': '/c.png',
      });
      expect(img.displayUrl, '/o.png');
    });

    test('parses enhancement fields with sensible defaults', () {
      final ai = ClothImage.fromJson({
        'id': 2,
        'role': 'front',
        'sort_order': 0,
        'bg_accepted': 'accepted',
        'original_url': '/o.png',
        'cutout_url': '/c.png',
        'enhanced_url': '/e.png',
        'enhance_status': 'ready',
        'enhance_method': 'ai',
        'enhance_pending_method': 'ai',
      });
      expect(ai.enhanceMethod, 'ai');
      expect(ai.enhanceStatus, 'ready');
      expect(ai.enhancedUrl, '/e.png');

      final plain = ClothImage.fromJson({
        'id': 3,
        'role': 'back',
        'sort_order': 1,
        'bg_accepted': 'pending',
        'original_url': '/o.png',
        'cutout_url': '/c.png',
      });
      expect(plain.enhanceMethod, 'none');
      expect(plain.enhanceStatus, isNull);
    });
  });

  group('Outfit', () {
    test('parses and preserves cloth order', () {
      final o = Outfit.fromJson({
        'id': 5,
        'model_id': null,
        'model_name': null,
        'cloth_ids': [3, 1],
        'cloths': [
          {'id': 3, 'name': 'Jeans', 'brand': ''},
          {'id': 1, 'name': 'Tee', 'brand': ''},
        ],
        'prompt': '',
        'generated_url': '/generated/5.png',
        'status': 'done',
        'is_mock': true,
        'model_tier': 'pro',
        'view': 'front',
        'is_favorite': false,
      });
      expect(o.clothIds, [3, 1]);
      expect(o.cloths.map((c) => c.name).toList(), ['Jeans', 'Tee']);
      expect(o.tierLabel, 'Pro');
    });

    test('outfitImageUrl adds a cache-busting token', () {
      final o = Outfit.fromJson({
        'id': 5,
        'cloth_ids': [],
        'cloths': [],
        'generated_url': '/generated/5.png',
        'status': 'done',
        'model_tier': 'flux',
        'view': 'front',
      });
      final url = outfitImageUrl(o);
      expect(url.contains('b=5-flux-front-done'), isTrue);
    });

    test('withLinkedId links the front to its back without touching the rest', () {
      final front = Outfit.fromJson({
        'id': 5, 'cloth_ids': [1], 'cloths': [], 'generated_url': '/g/5.png',
        'status': 'done', 'model_tier': 'pro', 'view': 'front',
        'is_favorite': true, 'linked_id': null,
      });
      final linked = front.withLinkedId(9);
      expect(linked.linkedId, 9);
      expect(front.linkedId, isNull); // original untouched
      expect(linked.id, 5);
      expect(linked.view, 'front');
      expect(linked.isFavorite, isTrue);
    });
  });

  group('AgendaEntry.fromJson', () {
    test('hydrates embedded outfit', () {
      final e = AgendaEntry.fromJson({
        'id': 1,
        'day': '2026-07-20',
        'outfit_id': 5,
        'title': 'Work',
        'note': '',
        'worn': true,
        'outfit': {
          'id': 5,
          'cloth_ids': [],
          'cloths': [],
          'generated_url': '/generated/5.png',
          'status': 'done',
          'model_tier': 'flux',
          'view': 'front',
        },
      });
      expect(e.worn, isTrue);
      expect(e.outfit, isNotNull);
      expect(e.outfit!.id, 5);
    });
  });

  group('Cloth.fromJson defaults', () {
    Cloth parse(Map<String, dynamic> extra) => Cloth.fromJson({
          'id': 1, 'user_id': 1, 'name': 'x', 'brand': '', 'cut': 'normal',
          'category': 'tshirt', 'custom_tags': <String>[], 'colors': <dynamic>[],
          'images': <dynamic>[], ...extra,
        });

    test('an unrated cloth scores 0, not 1', () {
      expect(parse(const {}).score, 0);
      expect(parse(const {'score': 4}).score, 4);
    });

    test('a never-worn cloth has no last_worn_at', () {
      expect(parse(const {}).lastWornAt, isNull);
      expect(parse(const {'last_worn_at': '2026-01-02'}).lastWornAt, '2026-01-02');
    });

    test('favourite and exclude default to false', () {
      expect(parse(const {}).isFavorite, isFalse);
      expect(parse(const {}).excludeFromAlgo, isFalse);
    });
  });

  group('outfitSlots for single-slot categories', () {
    test('socks, underwear and bags each occupy their own slot', () {
      // Without this, two bags or two pairs of socks could enter one outfit.
      for (final c in ['socks', 'underwear', 'bag']) {
        expect(outfitCategoriesConflict(c, c), isTrue, reason: '$c vs itself');
      }
      expect(outfitCategoriesConflict('socks', 'bag'), isFalse);
    });
  });

  group('detectBrandInName', () {
    test('recognises a known brand as a whole word (case-insensitive)', () {
      expect(detectBrandInName('nike black hoodie'), 'Nike');
      expect(detectBrandInName('My Adidas joggers'), 'Adidas');
    });
    test('matches multi-word brands by substring', () {
      expect(detectBrandInName('the north face jacket'), 'The North Face');
    });
    test('does not false-match a substring inside another word', () {
      // These genuinely contain a brand as a substring — "legapants" holds
      // "gap", "kappaish" holds "kappa". The previous example ("cheap grey
      // tee") contained no brand at all, so it passed whether matching was
      // whole-word or substring and proved nothing.
      expect(detectBrandInName('legapants'), isNull);
      expect(detectBrandInName('kappaish top'), isNull);
      // ...while the same brands as standalone words still match.
      expect(detectBrandInName('vintage gap'), 'Gap');
      expect(detectBrandInName('kappa top'), 'Kappa');
    });

    test('an empty or blank name yields null', () {
      expect(detectBrandInName(''), isNull);
      expect(detectBrandInName('   '), isNull);
    });
    test('falls back to the user\'s own brands', () {
      expect(detectBrandInName('Acme raincoat', extra: ['Acme']), 'Acme');
    });
    test('returns null when nothing matches', () {
      expect(detectBrandInName('plain white shirt'), isNull);
    });
  });

  group('detectCategoryInName', () {
    test('recognises a t-shirt however it is spelled', () {
      expect(detectCategoryInName('black t shirt'), 'tshirt');
      expect(detectCategoryInName('Nike T-Shirt'), 'tshirt');
      expect(detectCategoryInName('plain tshirt'), 'tshirt');
      expect(detectCategoryInName('white tee'), 'tshirt');
    });
    test('more specific types win over the generic "shirt"', () {
      expect(detectCategoryInName('navy polo shirt'), 'polo');
      expect(detectCategoryInName('grey tank top'), 'tank-top');
      expect(detectCategoryInName('blue dress shirt'), 'shirt');
      // "short"/"long sleeve" descriptors must not beat the actual "shirt".
      expect(detectCategoryInName('short sleeve shirt'), 'shirt');
      expect(detectCategoryInName('blue short'), 'shorts');
    });
    test('distinguishes sweatpants (jogging) from sweatshirt', () {
      expect(detectCategoryInName('grey sweatpants'), 'jogging');
      expect(detectCategoryInName('Nike joggers'), 'jogging');
      expect(detectCategoryInName('black sweatshirt'), 'sweatshirt');
      expect(detectCategoryInName('cosy sweat'), 'sweatshirt');
    });
    test('maps common synonyms and French terms to a valid category', () {
      expect(detectCategoryInName('white sneakers'), 'shoes');
      expect(detectCategoryInName('chaussures de sport'), 'shoes');
      expect(detectCategoryInName('sweat à capuche'), 'hoodie');
      expect(detectCategoryInName('sac à dos'), 'bag');
      expect(detectCategoryInName('casquette rouge'), 'cap');
      expect(detectCategoryInName('blue jean'), 'jeans');
    });
    test('every detected category is a valid dropdown option', () {
      for (final name in ['t shirt', 'polo', 'hoodie', 'jean', 'short',
        'pantalon', 'veste', 'sneakers', 'cap', 'bonnet', 'sac', 'socks',
        'boxer', 'chemise']) {
        final cat = detectCategoryInName(name);
        expect(cat, isNotNull, reason: 'no match for "$name"');
        expect(kCategoryOptions, contains(cat), reason: '"$name" -> $cat');
      }
    });
    test('returns null when no garment type is present', () {
      expect(detectCategoryInName('my favourite thing'), isNull);
      expect(detectCategoryInName(''), isNull);
    });
  });

  group('outfit layering slots', () {
    test('base, mid and outer layers can coexist', () {
      expect(outfitCategoriesConflict('tshirt', 'hoodie'), isFalse);
      expect(outfitCategoriesConflict('tshirt', 'jacket'), isFalse);
      expect(outfitCategoriesConflict('hoodie', 'jacket'), isFalse);
    });
    test('two of the same layer still conflict', () {
      expect(outfitCategoriesConflict('tshirt', 'polo'), isTrue); // two base tops
      expect(outfitCategoriesConflict('hoodie', 'sweatshirt'), isTrue); // two mids
      expect(outfitCategoriesConflict('jacket', 'coat'), isTrue); // two outers
    });
    test('a dress fills the whole upper + lower body', () {
      expect(outfitCategoriesConflict('dress', 'tshirt'), isTrue);
      expect(outfitCategoriesConflict('dress', 'hoodie'), isTrue);
      expect(outfitCategoriesConflict('dress', 'jeans'), isTrue);
    });
    test('isUpperBody flags tops/mids/outers only', () {
      expect(isUpperBody('tshirt'), isTrue);
      expect(isUpperBody('hoodie'), isTrue);
      expect(isUpperBody('jacket'), isTrue);
      expect(isUpperBody('jeans'), isFalse);
      expect(isUpperBody('socks'), isFalse);
    });
  });

  group('outfitCategoriesConflict (manual picker blocks same slot)', () {
    test('two bottoms conflict (jeans vs joggers vs trousers)', () {
      expect(outfitCategoriesConflict('jeans', 'jogging'), isTrue);
      expect(outfitCategoriesConflict('jeans', 'trousers'), isTrue);
      expect(outfitCategoriesConflict('jogging', 'shorts'), isTrue);
    });
    test('different slots do not conflict', () {
      expect(outfitCategoriesConflict('tshirt', 'jeans'), isFalse);
      expect(outfitCategoriesConflict('hat', 'socks'), isFalse);
    });
  });
}

void _enhancedPreviewTests() {
  group('the AI result is fetched at screen size', () {
    test('enhanced_preview_url is used when the server sends one', () {
      final img = ClothImage.fromJson(const {
        'id': 1,
        'enhanced_url': '/images/9/enhanced_1_x.jpg',
        'enhanced_preview_url': '/thumb/images/800/9/enhanced_1_x.jpg',
      });
      expect(img.enhancedPreview, contains('/thumb/'));
    });

    test('falls back to the stored file on an older server', () {
      // A backend that predates the field sends no enhanced_preview_url. Showing
      // nothing there would be worse than showing the big one.
      final img = ClothImage.fromJson(const {
        'id': 1,
        'enhanced_url': '/images/9/enhanced_1_x.jpg',
      });
      expect(img.enhancedPreview, '/images/9/enhanced_1_x.jpg');
    });

    test('stays empty when there is no AI result at all', () {
      expect(ClothImage.fromJson(const {'id': 1}).enhancedPreview, '');
    });
  });
}

void _cutoutStatusTests() {
  group('a garment can exist before its cut-out does', () {
    test('reads cutout_status from the server', () {
      final img = ClothImage.fromJson(const {
        'id': 1,
        'bg_accepted': 'pending',
        'cutout_status': 'processing',
      });
      expect(img.cutoutStatus, 'processing');
    });

    test('an older server, or a row from before the column, reads as ready', () {
      // Defaulting to anything else would put a spinner on a whole wardrobe of
      // photos that were cut out long ago.
      final img = ClothImage.fromJson(const {'id': 1});
      expect(img.cutoutStatus, 'ready');
    });

    test('a failed cut-out is a state of its own, not "still going"', () {
      final img = ClothImage.fromJson(const {'id': 1, 'cutout_status': 'failed'});
      expect(img.cutoutStatus, 'failed');
      expect(img.cutoutStatus, isNot('processing'));
    });
  });
}
