# LocalPorts

LocalPorts is a macOS menu bar application for monitoring and controlling local development services on `localhost`.

It combines:
- port discovery via `lsof`
- one-click service actions (open, copy URL, start, stop, restart, force stop)
- editable saved service cards (including custom project folders and start commands)
- a menu bar-first workflow (`LSUIElement` app, no Dock presence by default)

## Table of Contents
1. Overview
2. Core Features
3. Requirements
4. Quick Start
5. How to Use
6. Settings
7. Data Persistence
8. Project Structure
9. Service Lifecycle Details
10. Build and Deploy
11. Troubleshooting
12. Security and Distribution Notes

## 1. Overview

LocalPorts is designed for developers who run multiple local services and want a single control panel in the menu bar.

Current app metadata:
- Bundle ID: `com.localports.app`
- Version: `1.0 (1)`
- Minimum macOS target: `13.0`
- App mode: menu bar accessory (`LSUIElement = true`)

## 2. Core Features

### Menu Bar Interaction
- Left click menu bar icon: opens/closes the services popover.
- Right click (or Control-click) menu bar icon: opens context menu with:
  - `Settings`
  - `Quit`

### Services Panel
- Lists saved services under `Services` within the active profile.
- Profile menu supports:
  - switch profile
  - create profile
  - rename current profile
  - delete current profile (when more than one exists)
- Each card shows:
  - name
  - URL
  - runtime state (`Running`, `Stopped`, `Starting`, `Stopping`, `Error`)
  - health indicator (`Healthy`, `Checking`, `Unhealthy`) while running
- Card actions:
  - `Open` (browser)
  - `Copy URL`
  - `Start` / `Stop`
  - `More` menu:
    - `Rename`
    - `Reset Name` (if renamed)
    - `Restart` (if start is configured)
    - `Show in Finder` (if project folder exists)
    - `Edit`
    - `Force Stop`
    - `Remove Card` (custom services only)

### Add and Edit Service Cards
- Add custom service via `+` button.
- Edit existing service via card menu `Edit`.
- Folder selection supports Finder picker (`Browse...`).
- Optional per-service health check URL can be configured.

Validation rules:
- service name required (for new custom service)
- address must be valid and include explicit port
- health check address is optional, but if provided it must be localhost with explicit port
- only `localhost`, `127.0.0.1`, `::1` hosts are allowed
- port must be unique across saved services
- `Project Folder` and `Start Command` must be provided together

### Startup and Background Behavior
- App periodically refreshes listening ports every 2 seconds.
- On launch, startable saved services can be auto-started if not already running.
- Health checks run on active services at a throttled interval.
- Optional launch behavior:
  - `Start LocalPorts app on login`
  - `Launch in the background`
- If onboarding is not completed, services popover opens on launch once.

### Configuration Backup
- Export the full app configuration to a JSON file from Settings.
- Import configuration JSON from Settings; imported content is sanitized before being saved.
- Quick access to the active config file is available via `Show Config File`.

### Diagnostics for Start Failures
When a start command fails (or exits immediately), LocalPorts writes diagnostics to:
- `~/Library/Logs/LocalPorts/<service-id>.log`

Log entries include:
- timestamp
- service id and name
- working directory
- executed shell command
- exit status
- stdout
- stderr

## 3. Requirements

- macOS 13+
- Xcode 15+ (Xcode 16+ also works)
- Swift 5 toolchain
- `lsof` available at `/usr/sbin/lsof` (default on macOS)

Optional for managed starts:
- Node/npm or any runtime your service command needs
- project folders must exist locally

## 4. Quick Start

### Xcode
1. Open `LocalPorts.xcodeproj`.
2. Select scheme `LocalPorts`.
3. Run.

### Command Line Build
```bash
cd "<repo-root>"
xcodebuild -project LocalPorts.xcodeproj -scheme LocalPorts -configuration Debug build
```

### Run Installed App (if copied to /Applications)
```bash
open /Applications/LocalPorts.app
```

## 5. How to Use

### First Launch Checklist
1. Open popover from menu bar icon.
2. Review built-in cards and update them from `Edit` if folder/command paths are not valid on your machine.
3. Add your own services via `+`.
4. Use `Refresh` to rescan ports immediately.

### Start/Stop Flow
- `Play` button starts service if `Project Folder + Start Command` are configured.
- `Stop` sends `SIGTERM`.
- `Force Stop` sends `SIGKILL`.
- `Restart` performs stop then start.

### Rename Behavior
- Rename is display-only and stored separately.
- Resetting name restores original configured service name.

### Finder Integration
- `Show in Finder` opens configured project folder directly.

## 6. Settings

Open from:
- right click menu bar icon -> `Settings`

Available options:
- `Start LocalPorts app on login`
  - Uses `ServiceManagement` (`SMAppService.mainApp`) to register/unregister login item.
- `Launch in the background`
  - On: app stays in menu bar on startup.
  - Off: app opens services popover shortly after launch.

Settings panel also includes:
- startup explanations
- onboarding reset button (`Show onboarding again`)
- configuration backup tools (`Export`, `Import`, `Show Config File`)
- diagnostics log tools (`Refresh`, `Open Folder`, `Clear`, per-file `Open`)
- quick usage guide
- tips
- version and mode information

## 7. Data Persistence

LocalPorts now stores runtime configuration in a versioned JSON file:
- `~/Library/Application Support/com.localports.app/config.v1.json`
- automatic backup: `config.v1.json.bak`

Config includes:
- app settings (for example `launchInBackground`)
- onboarding completion state
- selected profile id
- all profiles and their services
- per-service custom display names
- optional per-service health check URL
- migration metadata

You can export and import this JSON from Settings (`Configuration Backup`). Imported files are sanitized (missing built-ins are restored, invalid profile references are corrected).

### Legacy Migration
On first run after this change, LocalPorts automatically migrates legacy `UserDefaults` keys into `config.v1.json`:
- `PinnedServiceNames.v1`
- `CustomServices.v1`
- `BuiltInServiceOverrides.v1`
- `LaunchInBackground.v1`

Legacy compatibility metadata is written to config and kept for a limited compatibility window.

## 8. Project Structure

```text
App/
  AppDelegate.swift
  LocalPortsApp.swift
  StatusBarController.swift
  Models/
    ListeningPort.swift
  Services/
    LsofService.swift
    ActionsService.swift
    ManagedServiceController.swift
  ViewModels/
    PortsViewModel.swift
  Views/
    PortsPopoverView.swift
  Assets.xcassets/
  Info.plist

LocalPorts.xcodeproj/
README.md
```

## 9. Service Lifecycle Details

### Discovery
- `LsofService` runs:
  - `/usr/sbin/lsof -nP -iTCP -sTCP:LISTEN`
- Parses rows, extracts `host:port`, filters to local/unknown host classes.

### Start Command Execution
- Managed starts run through:
  - `/bin/zsh -lc "<command>"`
- Process working directory is set to configured `Project Folder`.
- PATH is prefixed with:
  - `/usr/local/bin:/opt/homebrew/bin:$PATH:$PWD`

### Script Convenience
If first token in start command is a local file in working directory (for example `start.sh`), it is rewritten to `./start.sh` automatically.

### Auto Refresh and Auto Start
- periodic refresh timer every 2 seconds
- one-time launch auto-start attempt for startable services that are not already listening

## 10. Build and Deploy

### Release Build
```bash
cd "<repo-root>"
xcodebuild -project LocalPorts.xcodeproj -scheme LocalPorts -configuration Release build
```

### Install to /Applications
```bash
ditto \
  "$HOME/Library/Developer/Xcode/DerivedData/<DerivedDataFolder>/Build/Products/Release/LocalPorts.app" \
  "/Applications/LocalPorts.app"
```

### Verify Running Path
```bash
pgrep -fl '/Applications/LocalPorts.app/Contents/MacOS/LocalPorts'
```

## 11. Troubleshooting

### Settings or UI Looks Outdated
Likely an old app bundle is running.

Check:
```bash
pgrep -fl LocalPorts
ls -la /Applications/LocalPorts.app/Contents/MacOS/LocalPorts
```

Reinstall app from latest build and reopen.

### Service Fails to Start
Check diagnostics:
```bash
tail -n 200 ~/Library/Logs/LocalPorts/*.log
```

Typical causes:
- invalid project folder path
- missing runtime (`npm`, etc.) in PATH
- command exits immediately with error
- command requires env vars not set in shell

### Icon Not Updating in Finder/Dock
macOS icon cache can be stale.

Try:
```bash
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -R -trusted /Applications/LocalPorts.app
killall Finder || true
killall Dock || true
killall iconservicesagent || true
```

### Login Item Toggle Fails
- Requires macOS 13+
- Can fail due to app registration/signing context
- App surfaces error message in Settings panel

## 12. Security and Distribution Notes

- This repo is currently prepared for private publishing and local usage.
- Local/development signing may still trigger Gatekeeper warnings on other machines.
- For broad distribution without warning dialogs, use:
  - Developer ID signing
  - Apple notarization

---

