<div align="center">

<img src="dressly/assets/icon.png" alt="Dressly" width="96">

# Dressly

**Photograph your clothes once, then let the app put outfits together.**
A self-hosted wardrobe: a FastAPI + SQLite backend that cuts garments out of their
background and renders outfits with the FLUX image API, and a Flutter app to wear it from.

[![CI](https://github.com/myqzurdux3/dressly/actions/workflows/ci.yml/badge.svg)](https://github.com/myqzurdux3/dressly/actions/workflows/ci.yml)
![Backend](https://img.shields.io/badge/backend-FastAPI%20%2B%20SQLite-0b7285)
![App](https://img.shields.io/badge/app-Flutter-1c211f)
![Tests](https://img.shields.io/badge/tests-773%20backend%20%2B%20243%20app-2f9e44)

</div>

---

## What it does

- **Wardrobe** — one photo per garment (front/back, or several angles for shoes and bags).
  The background is removed on upload; you accept or reject the cut-out.
- **Outfits** — pick garments by hand, or let an algorithm choose: same brand, matching
  colours, never-worn, weather-driven, and a dozen more. The result is rendered on a model
  photo of your own.
- **Week planner** — seven days at once, with the same algorithms and no repeats.
- **Agenda** — what you wore and when, which feeds the "not worn in a while" picker.

## Quick start

Two parts. The backend runs anywhere with Python 3.11+; the app is built for Android.

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

The first garment you add downloads the `rembg` background-removal model (~170 MB, once).
Without a `BFL_API_KEY` the render calls return placeholder images, so everything else can
be tried offline.

> **Updating an installed app:** use `adb install -r`, not `flutter install` — the latter
> uninstalls first and wipes your session.

## Configuration

Everything is environment variables, with development defaults that just work.
`CLOTHESAPP_ENV=prod` makes the server refuse to start until the security-relevant ones are
set. Full table: [backend/README.md](backend/README.md#configuration) — start from
[backend/.env.example](backend/.env.example).

## Tests

```bash
cd backend  && python3 -m pytest          # 773 tests, ~4 min
cd dressly  && flutter test               # 243 tests, ~10 s
cd dressly  && dart analyze lib test      # must be clean
```

No test touches the network: the weather, balance and image-API calls are stubbed by
`backend/tests/conftest.py` and by a recording fake on the Flutter side.

## Layout

```
backend/     FastAPI app, SQLite schema + migrations, image pipeline, FLUX client
dressly/     Flutter app (lib/services, lib/state, lib/screens, lib/widgets)
.env.example      every setting, with what it costs to get it wrong
SECURITY.md       how to report a problem, and the settings that decide exposure
```

## Contributing

It is a personal project, but the workflow is written down in
[CONTRIBUTING.md](CONTRIBUTING.md): run both suites before committing, and keep comments
about *why* rather than *what*.

## License

All rights reserved — see [LICENSE](LICENSE). The code is published to be read,
not reused: ask if you want to do anything else with it.
