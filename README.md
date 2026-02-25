# LocalPorts

LocalPorts is a macOS menu bar app that helps you manage local services from one place.

![LocalPorts interface](docs/images/localports-ui.png)

Most people should install LocalPorts from GitHub Releases. Developer build details are kept at the end of this README.

## End User Guide (Releases)

### What's New in v1.0.4
- easier installation for first-time users with `LocalPorts-Install.command` (double-click installer flow)
- imported configs are now trusted automatically after sanitization (no separate `Trust Config` step)
- improved `Start LocalPorts app on login` behavior:
  - clearer error guidance when app is not under `/Applications`
  - quick button to open macOS Login Items settings
- release pipeline now ships ad-hoc signed app builds plus installer script asset

### What It Does
- shows your saved local services and their status (`Running`, `Stopped`, `Starting`, `Stopping`, `Error`)
- lets you open/copy URLs quickly
- can start, stop, restart, and force-stop services
- supports profiles so you can group services per project/context

### Download and Install
1. Open the latest release: `https://github.com/onderk-motion/LocalPorts/releases/latest`
2. Download both `LocalPorts-vX.Y.Z.zip` and `LocalPorts-Install.command` from the **Assets** section.
3. Unzip the file.
4. Make sure `LocalPorts-Install.command` is in the same folder as `LocalPorts.app`.
5. Double-click `LocalPorts-Install.command` and follow prompts.
6. The installer copies the app to `/Applications`, clears quarantine metadata, and opens LocalPorts.

### What Is `LocalPorts-Install.command`?
- it is a one-click installer script for non-technical users
- it closes any running LocalPorts process before install
- it copies `LocalPorts.app` into `/Applications`
- it removes quarantine metadata (when present) to reduce first-launch friction
- it opens LocalPorts after install
- if admin permission is needed, macOS asks for your password

If the script does not open on first try:
1. Right-click `LocalPorts-Install.command` and choose `Open`.
2. Click `Open` again in the confirmation popup.
3. If blocked by policy, go to `System Settings > Privacy & Security` and use `Open Anyway` for that file.

Manual fallback:
1. Drag `LocalPorts.app` into `/Applications`.
2. Try launching once with `open /Applications/LocalPorts.app`.
3. If macOS blocks the app, Control-click `LocalPorts.app` in Finder, choose `Open`, then confirm.
4. If it is still blocked, open `System Settings > Privacy & Security` and use `Open Anyway` for LocalPorts, then confirm with your password.

### Which Release File Should I Download?
- `LocalPorts-vX.Y.Z.zip`: the app package you should install
- `LocalPorts-Install.command`: recommended installer for non-technical users
- `LocalPorts-vX.Y.Z.zip.sha256`: optional integrity checksum
- `Source code (zip/tar.gz)`: source snapshot only, not a runnable app

Optional checksum verification:

```bash
cd ~/Downloads
shasum -a 256 -c LocalPorts-vX.Y.Z.zip.sha256
```

### First 2 Minutes
1. Click the LocalPorts icon in the menu bar.
2. Review built-in cards and update folder/command fields if needed.
3. Add your own service with `+`.
4. Set `Address` (`http://localhost:PORT`), then optionally `Project Folder` + `Start Command`.
5. Use `Test Command` before saving.
6. Use `Refresh` to trigger an immediate port scan.

### Core Usage
- Left click menu bar icon: open/close the services popover.
- Right click (or Control-click) icon: open `Settings` and `Quit`.
- Use the footer buttons: `Refresh`, `Settings`, `+` (add service), `Quit`.
- Card actions: `Open` (browser), `Copy`, `Start`/`Stop`, `More` (rename/restart/edit/show in Finder/force stop/remove custom card).

### Common Problems

#### "Application is not supported on this Mac"
- usually caused by downloading `Source code (zip)` instead of release asset
- requires macOS `13.0+`
- use recent release assets (`v1.0.2+`) for universal Intel + Apple Silicon builds

#### Service does not start
- open diagnostics in Settings, or inspect:

```bash
tail -n 200 ~/Library/Logs/LocalPorts/*.log
```

Likely causes: invalid folder path, missing runtime (`npm`, `pnpm`, etc.), or command exits immediately.

## Features

- menu bar-first workflow (`LSUIElement` accessory app)
- profile support (create, rename, switch, delete)
- service cards with status + health checks
- optional process details in card status line (`process` + `user`)
- browser preferences:
  - global browser for `Open`
  - per-service browser override in Add/Edit
- command presets (`npm run dev`, `pnpm dev`, `yarn dev`, `node server.js`)
- startup options: `Start LocalPorts app on login`, `Launch in the background`
- config export/import with safety checks
- imported configs are trusted automatically after sanitization
- start failure diagnostics with secret redaction

## Requirements

- macOS `13.0+`
- for managed starts: required runtime for your command (`node`, `npm`, `pnpm`, etc.)
- `lsof` at `/usr/sbin/lsof` (default on macOS)

## Data, Config, and Logs

- main config file: `~/Library/Application Support/com.localports.app/config.v1.json`
- automatic backup: `~/Library/Application Support/com.localports.app/config.v1.json.bak`
- diagnostics logs: `~/Library/Logs/LocalPorts/<service-id>.log`

Config import/export is available from Settings (`Configuration Backup`).

## Developer Guide

### Local Build (Xcode)
1. Open `LocalPorts.xcodeproj`.
2. Select scheme `LocalPorts`.
3. Build and run.

### Local Build (CLI)

```bash
cd "<repo-root>"
xcodebuild -project LocalPorts.xcodeproj -scheme LocalPorts -configuration Debug build
```

### Release Build (Ad-hoc Signed)

```bash
cd "<repo-root>"
xcodebuild -project LocalPorts.xcodeproj \
  -scheme LocalPorts \
  -configuration Release \
  -destination "generic/platform=macOS" \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGN_IDENTITY="-" \
  build
```

### CI and Release Automation
- CI workflow: `.github/workflows/ci.yml`
- local CI-equivalent smoke command:

```bash
./scripts/ci-smoke.sh
```

- release workflow: `.github/workflows/release.yml`
- release assets are created on tag push (`v*`) as `LocalPorts-vX.Y.Z.zip`, `LocalPorts-vX.Y.Z.zip.sha256`, and `LocalPorts-Install.command`

## Project Structure

```text
App/
  AppDelegate.swift
  LocalPortsApp.swift
  StatusBarController.swift
  Models/
  Services/
  ViewModels/
  Views/
  Assets.xcassets/
  Info.plist

LocalPorts.xcodeproj/
scripts/
README.md
```

## Security and Distribution Notes

- imported config files are sanitized before save
- imported configs are trusted automatically after sanitization
- logs redact common token/secret patterns
- current releases are ad-hoc signed (not notarized); some Macs may still require first-launch approval
- for fully warning-free distribution, sign with Developer ID and notarize via Apple

## Open Source Collaboration

- `LICENSE`
- `CONTRIBUTING.md`
- `CODE_OF_CONDUCT.md`
- `SECURITY.md`
