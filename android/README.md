# Loglinkr HR — Android app (TWA)

A thin **Trusted Web Activity** wrapper that ships the Loglinkr web app as a
focused **Face Attendance + HR** Android app. It opens the live PWA in the
device's Chrome engine (so camera, WebGL and the face-recognition pipeline work
exactly as in the browser) and locks it to the workforce modules via
`?app=hr`. Push to `main` updates the web app; the installed app follows
automatically — no re-install for content changes.

- **Launch URL:** `https://www.loglinkr.com/app?app=hr`
- **Package:** `com.loglinkr.hr`
- **What's shown:** Face Attendance kiosk, Attendance register, Punch IN,
  Attendance/Payroll setup, Team & Roles, Training, Petty Cash. Everything else
  is hidden and any stray link redirects back to the kiosk.

## Get the APK (no local setup)

1. GitHub → **Actions** → **Build Loglinkr HR APK** → **Run workflow**.
2. When it finishes, open the run and download the **`loglinkr-hr-apk`** artifact.
3. Unzip → `loglinkr-hr.apk`. Copy to the tablet, enable *Install unknown apps*
   for your file manager, tap to install.

## Full-screen (no browser bar)

The app runs full-screen only after `assetlinks.json` is live on the site:

- File is at `/.well-known/assetlinks.json` (already in the repo) and must be
  reachable at `https://www.loglinkr.com/.well-known/assetlinks.json`.
- It pins this app's signing fingerprint:
  `E1:08:C7:A2:A8:41:E7:D1:09:85:00:64:75:71:D4:13:F8:3E:92:C6:B8:E6:6E:DC:F6:96:B1:80:AE:1A:A5:97`

Until it's reachable, the app still works but shows a thin Chrome address bar.

## Signing

`android/keystore/loglinkr-hr.keystore` (password `loglinkr-hr`) is an **internal
sideload key** committed for convenience. For a Play Store release, generate a
fresh key, store it as repo secrets (`LLK_KEYSTORE_B64`, `LLK_STORE_PASS`,
`LLK_KEY_ALIAS`, `LLK_KEY_PASS`) — the workflow uses them automatically — and
update the fingerprint in `assetlinks.json`.

## Local build (optional)

Needs Android SDK (platform 34, build-tools 34) + JDK 17:

```
cd android
./gradlew :app:assembleRelease
# → app/build/outputs/apk/release/app-release.apk
```
