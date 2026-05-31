# Forge — Build, Test & Distribute

## Prerequisites

| Requirement | How to Install |
|---|---|
| **macOS 13 Ventura+** | Required — Forge is a native macOS app |
| **Xcode 15.2+** | Mac App Store → Xcode |
| **XcodeGen** | `brew install xcodegen` |
| **create-dmg** (optional) | `brew install create-dmg` (for styled DMG installer) |

> **Windows/Linux users:** You must copy the project to a Mac to build. Xcode only runs on macOS. Transfer via USB, Git, or AirDrop.

---

## Quick Start — Build & Run

```bash
cd macos-app

# 1. Generate Xcode project from project.yml
xcodegen generate

# 2. Open in Xcode
open Forge.xcodeproj

# 3. In Xcode: select "Forge" scheme → "My Mac" → press ⌘R
```

Forge launches in the **menu bar** (hammer icon). There's no Dock icon — it's menu-bar-only by design.

### Alternative: Command Line Build

```bash
xcodegen generate
xcodebuild -project Forge.xcodeproj -scheme Forge -configuration Debug build
```

The built app lands in `~/Library/Developer/Xcode/DerivedData/Forge-*/Build/Products/Debug/Forge.app`.

### Alternative: Swift Package Manager

```bash
swift build
swift run Forge
```

> SPM builds have limitations with menu bar apps. Use Xcode for full functionality.

---

## Testing

### Run Tests in Xcode

1. Open `Forge.xcodeproj`
2. Press **⌘U** (Product → Test)
3. Tests run against the ForgeTests target

### Run Tests from Terminal

```bash
xcodebuild test \
  -project Forge.xcodeproj \
  -scheme Forge \
  -destination 'platform=macOS' \
  -quiet
```

### What's Tested

| Area | Tests |
|---|---|
| Fuzzy Search | Exact match, partial match, no match, ranking |
| Module Registry | Registration, toggle, deduplication, categories |
| Zone Layouts | Two-column, three-column, four-quadrant geometry |
| FancyZones | ZoneRect properties, Codable round-trip |
| Calendar Events | Zoom/Meet/Teams URL detection, missing URL |
| Shortcut Bindings | Display strings, key names, Codable, defaults |
| Settings Manager | Lookup, update, reset single, reset all, unknown keys |
| CodableModifiers | Flag preservation, non-modifier stripping |

### macOS Permissions for Testing

Several modules need system permissions. macOS will prompt you on first use:

| Permission | Modules That Need It | Where to Grant |
|---|---|---|
| **Accessibility** | Window Manager, FancyZones, Key Remap, Mouse Highlight | System Settings → Privacy & Security → Accessibility |
| **Screen Recording** | Color Picker, Screen Ruler, Text Extractor, ZoomIt | System Settings → Privacy & Security → Screen Recording |
| **Calendars** | Calendar | System Settings → Privacy & Security → Calendars |

> **Tip:** For development, add both `Xcode.app` and `Forge.app` to the Accessibility list.

---

## Creating a .dmg Installer

### Option 1: Build Script (Recommended)

```bash
# Make the script executable
chmod +x scripts/build-dmg.sh

# Full build + DMG
./scripts/build-dmg.sh

# DMG only (reuse existing .app)
./scripts/build-dmg.sh --skip-build

# Build + DMG + notarize for distribution
./scripts/build-dmg.sh --notarize
```

Output: `build/Forge-YYYYMMDD.dmg`

### Option 2: Manual Steps

**Step 1 — Build Release archive:**

```bash
xcodegen generate

xcodebuild archive \
  -project Forge.xcodeproj \
  -scheme Forge \
  -configuration Release \
  -archivePath build/Forge.xcarchive \
  CODE_SIGN_IDENTITY="-" \
  ENABLE_HARDENED_RUNTIME=YES
```

**Step 2 — Extract .app from archive:**

```bash
cp -R build/Forge.xcarchive/Products/Applications/Forge.app build/Forge.app
```

**Step 3 — Create DMG:**

With `create-dmg` (styled, with Applications shortcut):
```bash
create-dmg \
  --volname "Forge" \
  --window-pos 200 120 \
  --window-size 660 400 \
  --icon-size 160 \
  --icon "Forge.app" 180 170 \
  --hide-extension "Forge.app" \
  --app-drop-link 480 170 \
  "Forge-1.0.0.dmg" \
  "build/Forge.app"
```

Without `create-dmg` (basic DMG via hdiutil):
```bash
mkdir -p build/dmg-staging
cp -R build/Forge.app build/dmg-staging/
ln -s /Applications build/dmg-staging/Applications
hdiutil create -volname "Forge" -srcfolder build/dmg-staging -ov -format UDZO Forge-1.0.0.dmg
rm -rf build/dmg-staging
```

---

## Code Signing & Notarization

### For Personal Use (no Apple Developer account)

The build is signed with a **free, self-signed code-signing certificate** named
`Forge Dev`. This is *not* ad-hoc (`-`): ad-hoc regenerates the signature on
every rebuild, which invalidates Keychain "Always Allow" grants and TCC
permissions (Accessibility, Screen Recording) each time — producing repeated
authorization prompts and lost permissions. A fixed cert keeps the *designated
requirement* constant, so those grants persist across rebuilds and app upgrades.

The app still shows a Gatekeeper warning on **other** Macs (a self-signed cert
isn't trusted by Apple — only notarization removes that). To bypass on another
Mac: right-click Forge.app → Open → "Open Anyway", or
`xattr -dr com.apple.quarantine /Applications/Forge.app`.

**One-time setup — create the `Forge Dev` certificate:**

Open **Keychain Access** → menu **Certificate Assistant → Create a Certificate…**

| Field | Value |
|---|---|
| Name | `Forge Dev` |
| Identity Type | Self Signed Root |
| Certificate Type | Code Signing |
| Let me override defaults | ✓ (set validity to e.g. 3650 days) |

It lands in your **login** keychain. Verify with:

```bash
security find-identity -p codesigning | grep "Forge Dev"
```

If you don't have this cert (e.g. a fresh clone on another machine), either
create it as above, or set `CODE_SIGN_IDENTITY: "-"` in `project.yml` to fall
back to ad-hoc signing.

### For Distribution (Apple Developer account required)

**Step 1 — Set your Team ID:**

Edit `project.yml`:
```yaml
settings:
  base:
    CODE_SIGN_IDENTITY: "Apple Development"
    DEVELOPMENT_TEAM: "YOUR_TEAM_ID"
```

Or pass it at build time:
```bash
xcodebuild archive \
  -project Forge.xcodeproj \
  -scheme Forge \
  -configuration Release \
  -archivePath build/Forge.xcarchive \
  CODE_SIGN_IDENTITY="Developer ID Application: Your Name" \
  DEVELOPMENT_TEAM="YOUR_TEAM_ID"
```

**Step 2 — Notarize:**

```bash
# Store credentials (one-time)
xcrun notarytool store-credentials "forge-notary" \
  --apple-id your@email.com \
  --team-id YOURTEAMID \
  --password YOUR_APP_SPECIFIC_PASSWORD

# Submit for notarization
xcrun notarytool submit Forge-1.0.0.dmg --keychain-profile "forge-notary" --wait

# Staple the ticket
xcrun stapler staple Forge-1.0.0.dmg
```

---

## Project Structure

```
macos-app/
├── project.yml                         # XcodeGen project spec
├── Package.swift                       # Swift Package Manager config
├── BUILD.md                            # This file
├── ExportOptions.plist                 # Archive export config
├── scripts/
│   └── build-dmg.sh                    # Automated build + DMG script
│
├── Forge/
│   ├── Sources/
│   │   ├── App/
│   │   │   ├── ForgeApp.swift          # @main entry point
│   │   │   └── AppDelegate.swift       # Menu bar, popover, hotkeys, modules
│   │   │
│   │   ├── Core/
│   │   │   ├── Module.swift            # ForgeModule protocol
│   │   │   ├── ModuleRegistry.swift    # Central module manager
│   │   │   ├── SettingsManager.swift   # JSON prefs + ShortcutBinding
│   │   │   └── HotkeyManager.swift     # Carbon global hotkeys
│   │   │
│   │   ├── Design/
│   │   │   └── ForgeTheme.swift        # Design tokens (Dot-inspired)
│   │   │
│   │   ├── Modules/
│   │   │   ├── Calendar/               # EventKit calendar + meeting URLs
│   │   │   ├── CommandPalette/         # ⌘⇧Space fuzzy search launcher
│   │   │   ├── WindowManager/          # Snap zones, always-on-top
│   │   │   ├── ColorPicker/            # System-wide pixel color (⌃⌥C)
│   │   │   ├── ScreenRuler/            # Pixel measurement (⌃⌥R)
│   │   │   ├── TextExtractor/          # OCR via Vision framework (⌃⌥T)
│   │   │   ├── ZoomIt/                 # Screen zoom + annotate (⌃⌥Z)
│   │   │   ├── FancyZones/             # Custom snap layouts (⌃⌥F)
│   │   │   ├── KeyRemap/               # Key remapping via CGEventTap
│   │   │   └── MouseHighlight/         # Cursor spotlight, click rings
│   │   │
│   │   └── UI/
│   │       ├── MenuBarView.swift       # Main popover (360pt)
│   │       ├── SettingsView.swift      # Preferences + shortcut recorder
│   │       └── Components/
│   │           └── ForgeComponents.swift
│   │
│   └── Resources/
│       ├── Assets.xcassets/            # App icon
│       ├── Info.plist                  # Privacy descriptions
│       └── Forge.entitlements          # Sandbox entitlements
│
└── ForgeTests/
    └── ForgeTests.swift                # Unit tests
```

## All Keyboard Shortcuts (User-Configurable)

| Action | Default Shortcut | Settings Key |
|---|---|---|
| Command Bar | ⌘⇧Space | commandPalette |
| Join Next Meeting | ⌘⇧J | joinMeeting |
| Always On Top | ⌃⌥A | alwaysOnTop |
| Color Picker | ⌃⌥C | colorPicker |
| Screen Ruler | ⌃⌥R | screenRuler |
| Text Extractor (OCR) | ⌃⌥T | textExtractor |
| ZoomIt | ⌃⌥Z | zoomIt |
| FancyZones Editor | ⌃⌥F | fancyZones |

All shortcuts can be changed in Settings → Keyboard Shortcuts. Click the shortcut field → press your new key combination → done. Changes apply instantly (no restart needed).

## Architecture Notes

- **Module System**: Every tool is a self-contained `ForgeModule`. Disabled modules consume zero CPU/memory.
- **No Electron**: Pure SwiftUI + AppKit. Cold launch < 250ms. Idle memory < 80MB.
- **Local-first**: Settings stored as JSON in `~/Library/Application Support/Forge/`. No servers, no accounts.
- **Carbon Hotkeys**: Global shortcuts use the Carbon Hot Key API for reliable system-wide capture.
- **Live Re-registration**: Changing a shortcut in Settings re-registers the Carbon hotkey immediately via Combine observation.
- **EventKit**: Calendar reads from macOS system calendars (iCloud, Google, Outlook, Exchange).
