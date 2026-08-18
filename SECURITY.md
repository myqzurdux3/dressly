# Security

## Reporting a vulnerability

Please **do not open a public issue** for anything that could be used against a
running instance.

Report it privately through GitHub's
[security advisories](https://github.com/myqzurdux3/dressly/security/advisories/new)
form. Include what you did, what happened, and what you expected instead — a
proof of concept helps but is not required.

This is a personal project maintained by one person: expect a first answer
within a few days rather than within hours.

## What this project is

Dressly is **self-hosted**. Every deployment is somebody's own server, its own
database and its own image-provider key. There is no shared service and no
account system beyond the one each operator runs.

If you run it, the parts that decide how exposed you are:

- `BFL_API_KEY` — read from the environment, never from the source. It bills
  real money per render; treat it like a password.
- `CLOTHESAPP_SECRET` — signs both session tokens and image URLs. Anyone who
  knows it can mint a token for any account, including an admin one, and forge
  a signature for any photo. Generate it (`python -c "import secrets;
  print(secrets.token_urlsafe(48))"`), keep it, never invent it by hand.
- `CLOTHESAPP_SIGN_IMAGE_URLS` — leave it on. With it off, image URLs are
  unauthenticated, which makes the wardrobe readable by anyone who can guess a
  path.
- Registration is open by default (`POST /auth/signup`). On a server exposed to
  the internet, close it or put the app behind your own front door once your
  accounts exist.

## Scope

Reports about a deployment that has been configured against the notes above
(no JWT secret, signing disabled, key committed to a fork) are configuration
issues rather than vulnerabilities in this code — but tell us anyway if the
defaults are what led you there, because that is a bug in the defaults.
