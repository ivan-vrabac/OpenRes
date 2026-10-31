# OpenRes

[![CI](https://github.com/ivan-vrabac/OpenRes/actions/workflows/ci.yml/badge.svg)](https://github.com/ivan-vrabac/OpenRes/actions/workflows/ci.yml)
[![License: CC BY-NC 4.0](https://img.shields.io/badge/license-CC%20BY--NC%204.0-lightgrey.svg)](LICENSE)

A self-hostable location-based business game, with its source open for non-commercial use.
You walk around the real world, survey for resources, lease hexes, run plants, grow your
Campus from a camp of tents into a corporate campus, and trade on a player market.

Made by **Ivan Vrabac** ([COPYRIGHT.md](COPYRIGHT.md)).

- **`app/`**: Flutter client (Android)
- **`server/`**: FastAPI + SQLite game server
- **`deploy/`**: Docker Compose template and reverse-proxy example
- **`tools/`**: art generators, asset and repository checks

> **Artwork notice**: some pictures in the repository are generated placeholders (flat
> coloured shapes with short labels). See [COPYRIGHT.md](COPYRIGHT.md).

## Quick start

```bash
# Server
cd deploy
cp .env.example .env
docker compose up -d --build        # http://127.0.0.1:8000, fresh database in a named volume

# App (Android emulator reaches the host at 10.0.2.2)
cd ../app
flutter pub get
flutter run --dart-define-from-file=config/branding.default.json
```

For a phone on your LAN, set `BIND_ADDRESS=0.0.0.0` in `deploy/.env`, then copy
`config/branding.default.json` to `config/branding.local.json` with
`"API_BASE_URL": "http://<your-pc-ip>:8000"` and build with that file.

## Documentation

- [docs/INSTALL.md](docs/INSTALL.md): requirements, building, server setup, database, dev vs production
- [docs/BRANDING.md](docs/BRANDING.md): app name, icon, theme, application ID, launcher icon variants
- [docs/FIREBASE.md](docs/FIREBASE.md): optional push notifications
- [CONTRIBUTING.md](CONTRIBUTING.md) · [SECURITY.md](SECURITY.md) · [CHANGELOG.md](CHANGELOG.md)

Players sign in with Google when the build has a `GOOGLE_CLIENT_ID`; otherwise with a
company name and password.

## Tests

```bash
cd server && pip install -r requirements-dev.txt && python -m pytest -q
cd app && flutter test
# optional: client ↔ running dev server
cd app && flutter test test/api_e2e_test.dart --dart-define=API_BASE_URL=http://127.0.0.1:8000
python tools/assets.py validate
python tools/check_repo.py          # secrets / player data / forbidden files
```

## Known limitations

- No in-app password reset; admins use `server/admin.py`. See [SECURITY.md](SECURITY.md).
- The map uses OpenStreetMap's public tile server; read its usage policy before
  deploying for many users.

## License

Copyright (c) 2026 Ivan Vrabac. OpenRes is licensed under
[CC BY-NC 4.0](LICENSE): you may use, change and share it for **non-commercial** purposes,
as long as you **credit the author**. Please credit it like this:

> Based on [OpenRes](https://github.com/ivan-vrabac/OpenRes) by Ivan Vrabac (CC BY-NC 4.0)

Commercial use needs written permission from the author. Third-party components:
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Assets: [COPYRIGHT.md](COPYRIGHT.md).
