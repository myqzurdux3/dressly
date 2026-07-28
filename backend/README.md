# Clothes App — Python backend

FastAPI + SQLite + `rembg` (background removal). Auth via JWT + bcrypt.

## Setup

```bash
cd backend
pip install -r requirements.txt
./run.sh          # serves on http://0.0.0.0:8000
```

The first `POST /clothes` triggers a one-time `rembg` model download (~170 MB
for `u2net`) cached under `~/.u2net/`.

## Configuration

`CLOTHESAPP_ENV` defaults to `dev`, which keeps the permissive local defaults.
Set it to anything else (`prod`) and the server **refuses to start** unless the
security-relevant variables are set properly:

| Variable | Dev default | Required in prod |
|---|---|---|
| `CLOTHESAPP_ENV` | `dev` | set to `prod` |
| `CLOTHESAPP_SECRET` | `dev-secret-change-me` | yes — ≥32 bytes, else JWTs are forgeable |
| `CLOTHESAPP_CORS` | `*` | yes — explicit comma-separated origins |
| `CLOTHESAPP_DATA_DIR` | `backend/data` | optional |
| `BFL_API_KEY` | unset → dry-run placeholders | optional |
| `CLOTHESAPP_GEN_RATE_LIMIT` | `30` / hour / user | optional (0 disables) |
| `CLOTHESAPP_ENHANCE_RATE_LIMIT` | `40` / hour / user | optional (0 disables) |
| `CLOTHESAPP_ORIGINAL_MAX_PX` | `2000` | optional |

```bash
export CLOTHESAPP_ENV=prod
export CLOTHESAPP_SECRET="$(python -c 'import secrets; print(secrets.token_urlsafe(48))')"
export CLOTHESAPP_CORS="https://app.example.com"
```

## Connecting from the Flutter app

- Android emulator → `http://10.0.2.2:8000`
- Physical device → `http://<this machine's LAN IP>:8000`

Set this in `clothesapp/lib/config/api_config.dart`.

## Endpoints

| Method | Path | Auth | Purpose |
|---|---|---|---|
| POST | `/auth/signup` | – | `{email,password}` → `{token,user}` |
| POST | `/auth/login` | – | `{email,password}` → `{token,user}` |
| GET | `/auth/me` | ✓ | current user |
| GET | `/clothes` | ✓ | list, with `sort/search/brand/color/cut/tag` query filters |
| GET | `/clothes/{id}` | ✓ | one cloth (owner-scoped) |
| POST | `/clothes` | ✓ | `multipart`: `name,brand,cut,category,colors(JSON),tags(JSON)` + `images[]` (first two = front/back) |
| PUT | `/clothes/{id}` | ✓ | update fields/colors/tags |
| DELETE | `/clothes/{id}` | ✓ | delete cloth + its image files |
| GET | `/autocomplete/brands` | ✓ | distinct brands across **all users** |
| GET | `/autocomplete/tags` | ✓ | distinct tags across **all users** |
| GET | `/images/...` | – | static image files |
| GET | `/health` | – | liveness |

### `POST /clothes` example

```
name        = "Black oversized hoodie"
brand       = "Nike"
cut         = oversize          # slim|normal|large|oversize
category    = hoodie
colors      = [{"color":"Black","dominance":"full"},{"color":"White","dominance":"little"}]
tags        = ["street","basket"]
images      = <front.jpg> <back.jpg> [<extra.jpg> ...]
```

## Notes

- Background removal runs in a worker thread (`run_in_threadpool`) and outside
  any transaction, so an upload neither blocks the event loop nor holds the
  SQLite write lock while ONNX inference runs.
- Files live under `backend/data/images/<cloth_id>/`. Both the original (JPEG,
  ≤2000 px, EXIF baked in) and the cutout (`*_cutout.webp`, transparent) are
  kept so a future "search the internet for a better image" step can replace the
  cutout without losing data.
- Image bytes are content-addressed under `backend/data/blobs/` and hard-linked
  into place, so the same photo on two clothes is stored once.
  `images.gc_orphan_blobs()` reclaims unreferenced blobs.
- `/thumb/{root}/{width}/{path}` serves cached, resized copies for the grids.
  `backend/data/thumbs/` is a derived cache and safe to delete at any time.
- `scripts/recompress_images.py` re-encodes images predating the above. It is a
  dry run unless given `--apply`.

## Storage layout

```
backend/data/
├── data.db            SQLite (schema version in PRAGMA user_version)
├── images/<cloth_id>/ per-cloth originals + cutouts (hard links into blobs/)
├── blobs/<ab>/<sha>   content-addressed image bytes, stored once
├── outfits/           generated renders
├── thumbs/<width>/    derived resize cache — disposable
├── staging/           in-flight uploads — disposable
└── logs/
```