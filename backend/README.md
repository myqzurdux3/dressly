# Clothes App — Python backend

FastAPI + SQLite + `rembg` (background removal). Auth via JWT + bcrypt.

## Setup

```bash
cd backend
pip install -r requirements.txt
./run.sh          # serves on http://0.0.0.0:80
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
| `CLOTHESAPP_GEN_RATE_LIMIT` | `600` / hour / user | optional (0 disables) |
| `CLOTHESAPP_ENHANCE_RATE_LIMIT` | `600` / hour / user | optional (0 disables) |
| `CLOTHESAPP_UPLOAD_MAX_BYTES` | `67108864` (64 MB) per photo | optional |
| `CLOTHESAPP_UPLOAD_MAX_FILES` | `30` per request | optional |
| `CLOTHESAPP_UPLOAD_MAX_TOTAL_BYTES` | `268435456` (256 MB) per request | optional |
| `CLOTHESAPP_MAX_IMAGE_MP` | `40` megapixels | optional |
| `CLOTHESAPP_GENERATE_DEADLINE_S` | `150` | optional |
| `CLOTHESAPP_ORIGINAL_MAX_PX` | `4000` | optional |
| `CLOTHESAPP_CUTOUT_LOSSLESS` | `1` | optional (0 = lossy WebP, ~30% faster uploads) |
| `CLOTHESAPP_CUTOUT_MAX_PX` | `1600` | optional |

```bash
cp .env.example .env
python -c 'import secrets; print(secrets.token_urlsafe(48))'   # -> CLOTHESAPP_SECRET
python scripts/make_cert.py --host <your-public-ip>            # prints the pin
./run-prod.sh
```

`run-prod.sh` differs from `run.sh` in that it drops `--reload`, binds
`0.0.0.0`, runs several workers, and serves HTTPS when `certs/` holds a
certificate. It refuses to start without a secret.

### What the two required variables are

`CLOTHESAPP_SECRET` is the key that signs login tokens — effectively the
server's master password. Anyone who knows it can mint a token for any account.
It is not something to invent: any random 32+ byte string works. Keep it secret
and keep it stable (changing it signs everyone out).

`CLOTHESAPP_CORS` is **not** a secret and must not be a random string. It lists
the websites allowed to call the API from a browser. It is a browser-only rule,
so the phone app ignores it; if the app never runs in a browser, any placeholder
does. Only `*` is refused, which is why it has to be set at all.

### TLS

`scripts/make_cert.py` generates a self-signed certificate and prints its
SHA-256 fingerprint. Put that fingerprint in `apiCertSha256` in
`dressly/lib/config/api_config.dart`.

The pin is what makes self-signed safe. A self-signed certificate is trusted by
nothing, so a client either disables verification — worse than plain HTTP,
because it looks encrypted while accepting anything an attacker presents — or it
pins, accepting exactly one certificate and nothing else. Pinned, the connection
cannot be intercepted even by someone holding a certificate from a real
authority.

Regenerating the certificate changes the pin. Update both together or the app
stops connecting.

Once a domain name is available, prefer a real certificate (Let's Encrypt behind
Caddy or nginx) and set `apiCertSha256` back to `''`: ordinary validation then
applies, with no pin to keep in sync and no browser warnings.

### When something is wrong

```bash
python scripts/doctor.py
```

Checks the environment, the certificate, the database paths and the thumbnail
cache, and names what to fix. Written after a restart came back on plain HTTP
because its certificate was missing — the app then reported `Handshake error in
client (wrong version number)`, which describes the far side of the connection
and says nothing about the cause.

run-prod.sh now refuses to start without a certificate rather than quietly
downgrading to HTTP. `CLOTHESAPP_ALLOW_PLAINTEXT=1` overrides that for local
testing.

### Workers

`CLOTHESAPP_WORKERS` defaults to 3. Rate-limit counters and generation job
ownership both live in SQLite, so workers stay consistent with each other — with
in-memory counters, N workers would have allowed N times the quota, and a
restarting worker would have failed the renders its siblings were running.

Size it to RAM rather than cores: each worker loads its own rembg model
(~200 MB).

### Image URL signing

`/images` and `/generated` are unauthenticated mounts, and paths like
`/images/3/front_0.jpg` are guessable from a sequential cloth id. Outside dev
every image URL therefore carries an expiring signature covering its path;
requests without a valid one get a 404 (not a 403 — a 403 would confirm which
paths exist). Signatures last `CLOTHESAPP_IMAGE_URL_TTL_S`, one week by default,
which keeps the client's image cache useful.

### Sign-in protection

`/auth/login` and `/auth/signup` are limited per IP: a budget on attempts and a
tighter one on failures, so a word-list run is cut off while someone mistyping
their own password is not.

## Moving the install to a server

```bash
./scripts/export_for_server.sh          # -> ../dressly-backend.tar
```

Use tar, not zip. Image bytes are stored once and hard-linked into two places
(`data/images/<cloth_id>/…` and the content-addressed `data/blobs/…`), so there
are about 1000 paths for 550 real files. tar stores the second path as a link;
zip has no concept of hard links and copies the bytes again — which is why a
400 MB directory becomes an 800 MB zip. Measured here: 433 MB as tar, 846 MB as
zip, for the same content.

Compressing further is not worth it: JPEG and WebP are already compressed, so
gzip costs minutes and saves almost nothing. Pass `--gzip` only if the network
is slower than the CPU.

Secrets are deliberately left out of the archive — `certs/` and `.env`. The
certificate has to be regenerated on the server anyway, since it is issued for
that host's address, and `CLOTHESAPP_SECRET` should travel through a password
manager rather than a tarball.

After extracting, run `scripts/relocate_paths.py --apply`. Image locations are
stored as absolute paths, so a moved install leaves every row pointing at the
old machine. The failure is quiet rather than loud: `public_url_for` cannot make
the path relative to `IMAGES_DIR`, falls back to a bare filename, and every
image in the app 404s at once. The script is idempotent.

## Connecting from the Flutter app

- Android emulator → `http://10.0.2.2:80`
- Physical device → `http://<this machine's LAN IP>:80`

Set this in `dressly/lib/config/api_config.dart`.

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
- Files live under `backend/data/images/<cloth_id>/`. Both the original (JPEG
  quality 95, EXIF baked in, resolution preserved up to 4000 px) and the cutout
  (`*_cutout.webp`, transparent, LOSSLESS) are kept so a future "search the
  internet for a better image" step can replace the cutout without losing data.
- Image bytes are content-addressed under `backend/data/blobs/` and hard-linked
  into place, so the same photo on two clothes is stored once.
  `images.gc_orphan_blobs()` reclaims unreferenced blobs.
- `/thumb/{root}/{width}/{path}` serves cached, resized copies for the grids.
  `backend/data/thumbs/` is a derived cache and safe to delete at any time.
- `scripts/recompress_images.py` re-encodes images predating the above, and
  `scripts/reencode_from_backup.py` rebuilds them from an untouched backup when
  the settings change (re-encoding an already-lossy file cannot recover detail).
  Both are dry runs unless given `--apply`.

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