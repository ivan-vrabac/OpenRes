# Branding and forks

All branding is set at build time from one JSON file passed to Flutter. The same file
drives the Dart code (`lib/branding.dart`) and the Android build (`app/build.gradle.kts`
reads Flutter's `dart-defines`).

```bash
cp app/config/branding.default.json app/config/branding.local.json   # *.local.json is gitignored
flutter build apk --release --dart-define-from-file=config/branding.local.json
```

| Key | Used for | Default |
|---|---|---|
| `APP_NAME` | Android launcher label, notification channel name | `Resources` |
| `APP_TITLE` | In-app title (login screen, task switcher) | = `APP_NAME` |
| `APP_ID` | Android `applicationId`, map tile User-Agent | `com.example.resources` |
| `API_BASE_URL` | Game server URL, no trailing slash | `http://10.0.2.2:8000` |
| `THEME_SEED` | Default accent colour, ARGB hex | `0xFF009688` (teal) |
| `LOGO_ASSET` | Optional image above the login title, e.g. `assets/branding/logo.png` | none |

You can also override any key on the Gradle side with `-P` (e.g. `-PAPP_ID=...`).

### Application ID

`com.example.resources` cannot be published to Google Play on purpose: every fork must
choose its own ID (`org.yourname.yourgame`). Changing the ID makes a separate app. It
does not upgrade an existing install, which needs the same ID **and** the same signing
key. The Kotlin namespace (`com.example.resources`) is independent and can stay.

### Icons

| What | Where |
|---|---|
| Default launcher icon | `app/android/app/src/main/res/mipmap-*/ic_launcher*.png` (+ `mipmap-anydpi-v26/ic_launcher.xml`) |
| Logo | any asset; set `LOGO_ASSET` |

Replace the files in place (same names and sizes); `python tools/assets.py validate` checks them.
