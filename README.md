<div align="center">

<img src="dressly/assets/icon.png" alt="Dressly" width="96">

# Dressly

**Photograph your clothes once. Get dressed by the app.**

A self-hosted wardrobe: a FastAPI + SQLite server that cuts garments out of their
photos, puts outfits together and renders them, and a Flutter app to use it from.

[![CI](https://github.com/myqzurdux3/dressly/actions/workflows/ci.yml/badge.svg)](https://github.com/myqzurdux3/dressly/actions/workflows/ci.yml)
![Backend](https://img.shields.io/badge/backend-FastAPI%20%2B%20SQLite-0b7285)
![App](https://img.shields.io/badge/app-Flutter-1c211f)
![Self-hosted](https://img.shields.io/badge/self--hosted-yes-2f9e44)

</div>

---

## Features

**Wardrobe**
- One photo per garment — front and back, or several angles for shoes and bags.
  The background is removed on upload; you keep or reject the cut-out.
- Brand, colours with their dominance, cut, tags, a 1–5 rating, favourites, and a
  per-garment "never pick automatically" switch.
- Optional AI clean-up of a photo (wrinkles out, studio light), staged for what the
  item is: clothes are laid flat, caps and bags keep their volume, shoes their shape.

**Outfits**
- Built by hand on a canvas, or picked by an algorithm: random, matching colours,
  one colour, one brand, one cut, a shared tag, least worn, or a colour/brand/tag
  you choose. Lock pieces and let the algorithm dress around them.
- Every algorithm dresses a person, not a list: a t-shirt under the hoodie, layers by
  the weather (or today's forecast), socks with shoes, colours checked against what
  is already worn, liked and rested pieces first.
- Rate each outfit. The ratings teach the generator which pieces go well together,
  and an outfit rated badly is not proposed again.
- An AI render on one of your model photos, and a hand-made montage, kept side by
  side on the same outfit — switch between them without redoing either.

**Stylist**
- A chat stylist (Claude) that reads the whole wardrobe, the weather and your agenda,
  searches and looks at the photos, and proposes outfits as cards.
- It can act when asked: save an outfit, render it, put it in the agenda, rate or
  favourite things, mark what you wore. Three speeds, from a few seconds to expert.

**Planning**
- Week planner: seven days at once, each dressed for its own forecast, with no
  piece repeated.
- Agenda of what you wore and when, which feeds "least worn" and the dormant list.
- Costs screen: what each render, enhancement and stylist message cost, per provider.

## How it fits together

```
 Flutter app ──HTTPS──▶ FastAPI ──▶ SQLite        (clothes, outfits, agenda, ratings)
                           │
                           ├──▶ rembg            background removal, on the server
                           ├──▶ FLUX (BFL)       outfit renders, photo clean-up
                           ├──▶ OpenRouter       optional second image provider
                           └──▶ Claude API       optional stylist
```

Every external service is optional. Without keys the image calls return placeholders
and the stylist tab says it is not set up, so the rest can be tried offline.

## Quick start

The backend runs anywhere with Python 3.11+; the app is built for Android.

```bash
# 1. backend
cd backend
pip install -r requirements.txt
./run.sh                     # http://0.0.0.0:80

# 2. app  (point lib/config/api_config.dart at your server first)
cd dressly
flutter pub get
flutter build apk --release
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

The first garment you add downloads the `rembg` model (~170 MB, once).

> **Updating an installed app:** use `adb install -r`, not `flutter install` — the
> latter uninstalls first and wipes your session.

The app also runs on the Linux desktop (`flutter run -d linux`), which is how the
screens are checked without a phone.

## Configuration

Everything is an environment variable with a development default that works.
`CLOTHESAPP_ENV=prod` makes the server refuse to start until the security-relevant ones
are set. Start from [backend/.env.example](backend/.env.example); the full table is in
[backend/README.md](backend/README.md#configuration).

| Service | Variable | Without it |
|---|---|---|
| FLUX renders and clean-up | `BFL_API_KEY` | placeholder images |
| Second image provider | `OPENROUTER_API_KEY` | BFL only |
| Stylist | `ANTHROPIC_API_KEY` | stylist tab disabled |

## Tests

```bash
cd backend && python3 -m pytest          # API, generator, migrations, stylist
cd dressly && flutter test               # models, services, widgets, screens
cd dressly && dart analyze lib test      # must be clean
```

No test touches the network: weather, balances and the image and Claude APIs are
stubbed by `backend/tests/conftest.py` and by fakes on the Flutter side. CI runs all
three on every push.

## Layout

```
backend/            FastAPI app
  generator.py      outfit algorithms and the composer behind them
  stylist.py        the stylist's tools and conversation loop
  db.py             schema and migrations
  bfl.py, enhance.py, openrouter.py   image providers and photo clean-up
dressly/            Flutter app — lib/{models,services,state,screens,widgets,design}
SECURITY.md         how to report a problem, and the settings that decide exposure
CONTRIBUTING.md     the workflow: both suites green before a commit
```

## License

All rights reserved — see [LICENSE](LICENSE). The code is published to be read, not
reused: ask if you want to do anything else with it.
