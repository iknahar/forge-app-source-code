# Forge — Session Handoff

A macOS menu-bar productivity utility (Swift/SwiftUI/AppKit, deployment target macOS 14). Built for the **Strativ design team** (Stockholm + Dhaka, Swedish IT consultancy). This document hands off the project state so any new session can continue without losing context.

---

## 1. Project bootstrap

```
Project root:     /Users/strativa/Desktop/macos-app/
Xcode project:    Forge.xcodeproj   (regenerated from project.yml via xcodegen)
Bundle ID:        com.strativ.forge  (rename pending — see §10)
Deployment:       macOS 14+
LSUIElement:      true (menu-bar only, no Dock icon)
```

### Common commands

```bash
# Regenerate project after adding/removing source files
cd /Users/strativa/Desktop/macos-app && xcodegen generate

# Build
xcodebuild -project Forge.xcodeproj -scheme Forge -configuration Debug \
    -destination 'platform=macOS' build

# Force-kill + relaunch
killall -9 Forge 2>/dev/null; sleep 1
open /Users/strativa/Library/Developer/Xcode/DerivedData/Forge-blnasyzzqiuxoqcargwjyxmxzufk/Build/Products/Debug/Forge.app

# Tail FancyZones debug log
tail -f ~/Library/Logs/Forge/fancyzones.log
```

When adding new `.swift` files, **always** run `xcodegen generate` before building — otherwise the file isn't in the project target.

---

## 2. Codebase layout

```
Forge/
├── Resources/
│   └── Info.plist                            # CFBundleIdentifier = com.strativ.forge
└── Sources/
    ├── App/
    │   ├── AppDelegate.swift                 # Status item, popover, hotkey wiring, module registration
    │   └── ForgeApp.swift                    # @main; Settings scene only
    ├── Core/
    │   ├── Module.swift                      # ForgeModule protocol + ModuleCategory enum + ForgeShortcut
    │   ├── ModuleRegistry.swift              # @Published modules + enabled-state dictionary
    │   ├── SettingsManager.swift             # All persisted settings + shortcut bindings + per-action enable
    │   ├── HotkeyManager.swift               # Carbon RegisterEventHotKey wrapper
    │   └── ScrollableContainer.swift         # NSScrollView-backed wrapper (SwiftUI ScrollView swallows wheel in NSPopover)
    ├── Design/
    │   └── ForgeTheme.swift                  # Single source of truth for ALL colors/typography/radius/spacing/animation
    ├── UI/
    │   ├── MenuBarView.swift                 # Popover content (Calendar tab + Tools tab + gear)
    │   └── SettingsView.swift                # Top-tab settings window (General / Calendar / Key Remap / Menu Bar / Shortcuts / About)
    └── Modules/
        ├── Calendar/                         # CalendarModule, FullCalendarView, CalendarView, QuickCreateEventSheet,
        │                                     # EventDetailCardPopover, AttendeePickerField, ContactsDirectory,
        │                                     # WorldClockManagerPopover, MeetingLauncher
        ├── ClaudeLauncher/                   # ClaudeLauncherModule (Open Terminal + Open Terminal · Claude)
        ├── Clipboard/                        # ClipboardModule, ClipboardHistoryView
        ├── ColorPicker/                      # ColorPickerModule
        ├── FancyZones/                       # FancyZonesModule, FancyZonesEditorView, CustomLayoutBuilder
        ├── GoogleCalendar/                   # GoogleCalendarService (OAuth + Calendar v3 REST)
        ├── KeyRemap/                         # KeyRemapModule, KeyRemapEditor (CGEventTap-based)
        ├── MeetingReminder/                  # MeetingReminderModule (floating banner)
        ├── MouseHighlight/                   # MouseHighlightModule (Find My Mouse + Click Highlighter)
        ├── ScreenRuler/                      # ScreenRulerModule
        ├── Screenshot/                       # ScreenshotAnnotateModule, ScreenTranslator, TranslationOverlayPanel
        ├── TextExtractor/                    # TextExtractorModule (Vision OCR)
        ├── WindowManager/                    # WindowManagerModule (Pin Window via SkyLight CGSSetWindowLevel)
        └── ZoomIt/                           # ZoomItModule
```

`Modules/CommandPalette/` was **deleted** — the command bar feature was removed entirely.

---

## 3. Standing rules (DO NOT VIOLATE)

### Forge theme — `ForgeTheme.swift` is the only source of truth

| Use | Don't use |
|---|---|
| `ForgeTheme.Colors.accent` (vermillion red `#E72903`) | raw `.blue`, raw `.red` |
| `ForgeTheme.Colors.surfaceCard` / `surfaceHover` / `surfaceSubtle` | hard-coded `Color.white` / `Color(white:)` |
| `ForgeTheme.Colors.borderDefault` / `borderSubtle` | hard-coded `Color.black.opacity(...)` |
| `ForgeTheme.Colors.textPrimary` / `textSecondary` / `textTertiary` | raw `.primary` / `.secondary` (except inside menus) |
| `.toggleStyle(.forge)` | system `.switch` |
| `ForgeTheme.Spacing.{xs/sm/md/lg/xl}` (4/8/12/16/24) | magic numbers |
| `ForgeTheme.Radius.{small/medium/large/full}` (6/8/12/9999) | magic numbers |
| `ForgeTheme.Animation.{micro/smooth/medium/panel/popover}` | bespoke springs |
| System sounds: `Submarine`, `Pop`, `Tink`, `Glass` | shipped audio files |

### Reference images = behavior + structure ONLY

Visual style ALWAYS conforms to Forge. If a reference shows Windows-blue or Apple-blue accents, re-skin to Forge red. If a reference shows light-mode cards, ensure dark-mode adaptive tokens.

### Dark mode

Every new surface gets sanity-checked against dark mode. No hard-coded `Color.white` / `Color.black` unless semantically correct (e.g. button label that's always white on a colored fill).

### Settings opens on top

`MenuBarView.openSettingsForeground()` activates Forge, opens Settings, and raises it via `findSettingsWindow()`. Don't use SwiftUI's `SettingsLink` — it stays behind other apps for `LSUIElement` apps.

### `ScrollableContainer` for vertical scrolling inside popover

Forge's main popover wraps content in `ScrollableContainer` (NSScrollView shim) because SwiftUI's `ScrollView` swallows wheel events inside an `NSPopover`. **Don't nest a SwiftUI `ScrollView` inside the popover** — it will block parent scrolling. World clock strip uses a manual `DragGesture`-driven offset for this reason.

---

## 4. Feature inventory — what's DONE

### Calendar (the home screen)

- ✅ **EventKit integration** — reads all calendars (iCloud, Google, Outlook, Exchange, IMAP) from macOS System Settings → Internet Accounts
- ✅ **Native Google Calendar v3 API** (`GoogleCalendarService`) — full create/edit/delete/RSVP, generate Meet links via `conferenceData.createRequest`, attachments, popup reminders
- ✅ **Loopback PKCE OAuth flow** — `LoopbackOAuthServer` listens on ephemeral port, no Cloud Console URI registration needed
- ✅ **Bundled OAuth Client ID** (`defaultClientID` in `GoogleCalendarService.swift`) — currently in Testing state, only whitelisted emails can log in
- ✅ **Popover home (`CalendarView`)** — month grid, day-summary banner, year/day progress strips, today list, world clock strip
- ✅ **Full calendar (`FullCalendarView`)** — week view with hourly grid, drag-to-create slot, click-event side panel
- ✅ **`EventDetailCardPopover`** — floating card on event click in popover; Personal pill, countdown badge ("NOW" / "in 13h 39m"), Join button with provider-tinted icon, attachment row with Drive/Notion/Figma/GitHub favicons, paperplane URL row, Notes, Copy submenu (Details / Title / Location / Meeting Link / Notes), Edit / Reminder / Delete footer
- ✅ **`EventDetailSidePanel`** — same content for the full-calendar right rail; supports light + dark
- ✅ **Quick-create natural-language sheet (`QuickCreateEventSheet`)** — single-line input ("Fundraising chat at 2pm today with google meet"), live-parsed preview, editable rows for Location / Meeting link / Reminder / Notes / Add Google Meet, recurrence chips (Daily/Weekly/Monthly)
- ✅ **`NaturalLanguageEventParser`** — extracts title, day (today/tomorrow/weekday/next-X), time ("at 2pm", "14:00-15:30"), URL, location ("at Place"), recurrence keywords, Meet intent
- ✅ **`NewEventSheet`** (full editor) — title + time + all-day toggle, RSVP buttons, attendees (with autocomplete), attachments editor, reminders, calendar account picker
- ✅ **Attendee autocomplete (`AttendeePickerField` + `ContactsDirectory`)** — indexes past Google attendees by frequency + recency, colored avatar circles, deduped on email
- ✅ **World clock strip with drag-to-reveal + double-click manager popover** — `WorldClockManagerPopover` reorder + add cities
- ✅ **Right-click on day cell → "Create Event"** — opens QuickCreateEventSheet with the clicked date pre-seeded (9 AM)
- ✅ **`MeetingLauncher`** — Join buttons prefer native `zoommtg://` / `msteams:/` / `webex://` deep-links when those apps are installed, falls back to HTTPS
- ✅ **Meeting URL detection broadened** — Zoom `/j/`, `/s/`, `/my/`, `/wc/join/`; Teams `meetup-join`, `meeting`, `teams.live.com/meet/`; Webex `meet/`, `webappng/sites/`, `wbxmjs/joinservice`
- ✅ **Meeting Reminder banner (`MeetingReminderModule`)** — compact white/dark banner before/at meetings, attendee badge, attachment popover, RSVP dropdown, sound on appear
- ✅ **Menu-bar tokens** — date/time/next event/ongoing meeting with red pulsing dot, day/year progress %, configurable
- ✅ **Settings → Calendar** — calendar display toggles, Google account list with color pickers, meeting reminder style

### Screen tools

- ✅ **Screenshot & Annotate (`ScreenshotAnnotateModule`)** — Lightshot-style region capture, in-place pixels, annotation tools (rect/ellipse/freehand/arrow/text), upload to catbox.moe
- ✅ **On-screen translator (`ScreenTranslator` + `TranslationOverlayPanel`)** — OCR with Vision, per-block bounding boxes, Google Translate + MyMemory fallback, offline badge, source/target language dropdowns OUTSIDE selection, × closes only translator (screenshot stays alive)
- ✅ **Color Picker (`ColorPickerModule`)** — magnified loupe, click-to-copy in HEX/RGB/HSL
- ✅ **Screen Ruler** — pixel measurement with edge snapping
- ✅ **Text Extractor (OCR)** — Vision-based OCR of any region
- ✅ **ZoomIt** — screen zoom + live annotation

### Window management

- ✅ **Pin Window (`WindowManagerModule.togglePinWindow`)** — ⇧⌥W. Uses **SkyLight private API** (`CGSSetWindowLevel`) to actually elevate above other apps (AXRaise alone wasn't enough). Red border overlay tracks the pinned window's frame at 60ms polling, auto-hides on minimise, auto-releases on app quit. Submarine sound on pin, Pop on unpin.
- ✅ **FancyZones (`FancyZonesModule`)** — Editor at ⌥⇧`, drag-snap with Shift+drag, snap-to-zone via Accessibility API
- ✅ **FancyZones Editor (`FancyZonesEditorView`)** — PowerToys-style template gallery (No layout / Focus / Columns / Rows / Grid / Priority Grid), per-template edit sheet (number of zones, space around, highlight distance, orientation defaults), Custom layouts section, monitor strip at top
- ✅ **Custom Layout Builder (`CustomLayoutBuilder`)** — full-screen translucent splitter overlay. Hover → red horizontal suggestion line, hold Shift → vertical, click → commit split. Resizers between adjacent zones with circular grab pucks, drag to resize, perpendicular grip bars. Tab / ⇧Tab cycle zones + resizers, Delete merges, ← → ↑ ↓ nudge focused resizer. Floating Forge-styled help card (draggable from top bar, red Save + secondary Cancel buttons, custom `SplitterHelpButton`). Each zone shows its number + pixel dimensions ("585 × 1000").
- ✅ **Per-monitor `configForScreen`** — currently returns `activeConfig` (user's most recent pick wins on every screen). Orientation-default stars are persisted but not consulted at snap time yet.

### Input + accessibility

- ✅ **Find My Mouse** — double-tap **right** Command (no editable keystroke shortcut), spotlight ring around cursor
- ✅ **On Click Highlight (`MouseHighlightModule.toggleClickHighlighter`)** — ⌘⌥H toggles on/off. Small yellow disc (22pt radius, 44pt diameter) on each click, 1-second total animation (5% fade-in / 80% hold / 15% fade-out). Persists until toggled off.
- ✅ **Key Remap (`KeyRemapModule`)** — single-key + combo remapping via CGEventTap. Bare-key support via `allowsBareKey` flag on `ShortcutRecorderView`.

### Files + utilities

- ✅ **Clipboard History (`ClipboardModule`)** — ⌃⌥V. Polls `NSPasteboard.changeCount` every 600ms, captures text/image/files, dedupes against previous entry, max 100 entries (oldest non-pinned evicted), top 20 images persist across launches. Floating panel (`ClipboardHistoryPanel`) with search, pin, remove, click-to-paste-back, type-pill (TEXT/IMAGE/FILES), provider thumbnails.
- ✅ **Claude Code launcher (`ClaudeLauncherModule.launch`)** — ⌃⌥K. AppleScript opens Terminal and runs `claude`. Falls back to install hint if missing.
- ✅ **Open Terminal (`ClaudeLauncherModule.launchPlainTerminal`)** — ⌃⌥⇧T. Plain Terminal window, no command.

### Settings

- ✅ **Tabs**: General / Calendar / Key Remap / Menu Bar / **Shortcuts** / About
- ❌ **Removed tabs**: Modules (per-action enable toggle in Shortcuts replaces it), Windows (Snap modifier + Pin Window now live in Shortcuts → Window Management)
- ✅ **Shortcuts tab grouped by association**:
  - Calendar & Meetings: Join Next Meeting
  - Window Management: Pin Window, FancyZones Editor, FancyZones Snap (Shift+Drag — gesture row)
  - Screen Tools: Screenshot, Color Picker, Screen Ruler, Text Extractor, ZoomIt
  - Mouse & Highlights: Find My Mouse (Double-tap right ⌘ — gesture row), On Click Highlight
  - Files & Clipboard: Clipboard History
  - Developer: Open Terminal, Open Terminal · Claude
- ✅ **Per-action enable/disable** (Forge red pill toggle). Disabled rows: dimmed to 55%, hotkey not registered, gesture handlers no-op via bridge closures from `AppDelegate.registerModules`.
- ✅ **Per-action description** under each name.
- ✅ **`StaticGestureRow`** for non-keystroke triggers (label like "Double-tap right ⌘" or "Shift + Drag").
- ✅ **Calendar preview pane** widened to 320pt only for Calendar tab; full month grid; respects real `colorScheme` (no more hard-coded `isDark: false` previews).
- ✅ **Settings opens on top** via `openSettingsForeground` (LSUIElement workaround).

### Theme + persistence

- ✅ Every setting persists to `~/Library/Application Support/Forge/settings.json` via `PersistedSettings` Codable struct.
- ✅ Google tokens in Keychain under service `com.strativ.forge.google`.
- ✅ Clipboard history in `UserDefaults` keyed `clipboard.history` (text + 20-most-recent image blobs).
- ✅ FancyZones layouts in `~/Library/Application Support/Forge/fancyzones_layouts.json` (templates + custom layouts + active layout ref).

---

## 5. Default shortcuts

| Action | Default | Notes |
|---|---|---|
| Join Next Meeting | ⌘⇧J | Opens via MeetingLauncher (native app preferred) |
| Pin Window | ⇧⌥W | Red border, Submarine sound |
| FancyZones Editor | ⌥⇧` | PowerToys-style template gallery |
| FancyZones Snap | **Shift + Drag** | Gesture (not editable) |
| Screenshot & Annotate | ⌃⌥S | Lightshot flow + translate |
| Color Picker | ⌃⌥C | |
| Screen Ruler | ⌃⌥R | |
| Text Extractor | ⌃⌥T | Vision OCR |
| ZoomIt | ⌃⌥Z | |
| Find My Mouse | **Double-tap right ⌘** | Gesture (not editable) |
| On Click Highlight | ⌘⌥H | Toggle on/off |
| Clipboard History | ⌃⌥V | |
| Open Terminal | ⌃⌥⇧T | |
| Open Terminal · Claude | ⌃⌥K | |

All keystroke shortcuts user-rebindable in Settings → Shortcuts. Gestures are hard-wired.

---

## 6. KNOWN BUG — actively debugging at session end

### The bug
**FancyZones shift-drag snap does nothing** for the user. Drag-overlay highlights work fine (custom layout shows with red zone tracking the cursor), but on release no window resize happens.

### Diagnostic logging now in place
`fzLog(...)` writes to `~/Library/Logs/Forge/fancyzones.log`. Latest format:

```
[FZ] capture OK: app=Safari via=AXFocusedWindow trusted=true
[FZ] capture: AXFocusedWindow failed err=-25211 trusted=false app=Chrome
[FZ] capture: windows list failed err=-25211 app=Chrome
[FZ] mouseUp snapNow=true capturedTarget=true
[FZ] snap: zone=Zone 1 target=(...) layoutZones=2
[FZ] resize: before=(...) targetPos=(...) targetSize=(...)
[FZ] resize: sizeErr=0 posErr=0 after=(...)
[FZ] resize: NO CHANGE detected, retrying in 0.15s
```

### Last log dump from user (running an OLDER build)
Every `capture: AX lookup failed for app=...` (Chrome, Claude, Terminal) — old format, doesn't include `err=` or `trusted=`. This confirms the user was running a stale binary.

### Root cause hypothesis (very high confidence)
**Forge does not have Accessibility permission**, despite the user thinking it does. Debug builds get re-signed on every rebuild and macOS silently invalidates the Accessibility trust entry. `AXUIElementCopyAttributeValue` against another app's element returns `kAXErrorAPIDisabled (-25211)` when the calling process isn't trusted.

### Fix already in code (waiting on user verification)
1. **3-step AX fallback** in `captureDragTarget`: `kAXFocusedWindowAttribute` → `kAXMainWindowAttribute` → first entry of `kAXWindowsAttribute`.
2. **Auto-prompt**: if all three fail AND `AXIsProcessTrusted()` is false, fire `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])` + Forge-side alert with "Open System Settings" button (deep-links to Privacy & Security → Accessibility).
3. **AX error code + trust state logged** on every failed attempt.

### Next-session action
Ask the user to:
1. `rm -f ~/Library/Logs/Forge/fancyzones.log`
2. Force-relaunch Forge from the Debug build path
3. Open **System Settings → Privacy & Security → Accessibility**, toggle Forge OFF then ON (or remove + re-add)
4. `tail -f ~/Library/Logs/Forge/fancyzones.log`
5. Shift-drag a Safari window onto a zone

If the log shows `capture OK: app=Safari ... trusted=true` and `resize: ... after=(...)` matches the target rect, the bug is fixed. If `trusted=false` still, the auto-prompt didn't fire — needs deeper investigation.

---

## 7. Architecture rules + patterns

### Module pattern
Every utility conforms to `ForgeModule` (in `Core/Module.swift`):

```swift
protocol ForgeModule: AnyObject, Identifiable {
    var id: String { get }
    var name: String { get }
    var description: String { get }
    var iconName: String { get }
    var category: ModuleCategory { get }
    var isEnabled: Bool { get set }
    func activate()
    func deactivate()
    @ViewBuilder func menuBarView() -> AnyView   // default = EmptyView()
    func shortcuts() -> [ForgeShortcut]          // default = []
}
```

`ForgeCommand` + `commands()` method **were removed** with the Command Palette deletion.

Modules register in `AppDelegate.registerModules()`. Shortcuts wire in `AppDelegate.registerAllHotkeys()` via `registerHotkey(_:binding:handler:)` which:
- Skips disabled actions (`settingsManager.isActionEnabled`)
- Re-runs whenever `shortcutBindings` OR `actionEnabled` published values change

### Gesture handler enable/disable bridge
For non-keystroke triggers, the module exposes a closure that AppDelegate sets:

```swift
// MouseHighlightModule
var isFindMyMouseGestureEnabled: () -> Bool = { true }

// AppDelegate.registerModules
mouseHighlightModule.isFindMyMouseGestureEnabled = { [weak self] in
    self?.settingsManager.isActionEnabled("findMyMouse") ?? true
}
```

The module's gesture handler consults the closure and no-ops when disabled. Same pattern for FancyZones snap (`isSnapGestureEnabled`).

### `ScrollableContainer` (NSScrollView shim)
Don't use SwiftUI `ScrollView` inside `NSPopover` — it swallows scroll wheel events. World clock strip uses a manual `DragGesture` + `clipped()` viewport with `.overlay` to keep the popover's vertical scroll working.

### `MeetingLauncher.open(url:)`
Always route meeting URL opens through this. It builds the native deep-link, checks via `urlForApplication(toOpen:)` if a handler exists, falls back to HTTPS otherwise.

### FancyZones zone coordinate convention
**Zones use TOP-LEFT origin** (y=0 = top of screen). The splitter UI authors with this convention; the snap path and overlay must flip Y when converting to NSScreen (bottom-left) or AX (top-left, anchored at primary screen). This was a latent bug fixed in `absoluteRect(for:in:)` and `ZoneOverlayView.isFlipped = true`.

### Pin Window uses SkyLight private API
```swift
@_silgen_name("CGSMainConnectionID") private func CGSMainConnectionID() -> Int32
@_silgen_name("CGSSetWindowLevel")   private func CGSSetWindowLevel(_ cid: Int32, _ wid: CGWindowID, _ level: Int32) -> Int32
```
Standard approach for all macOS always-on-top utilities (Magnet, Rectangle Pro, PowerToys port). Stable since 10.6.

---

## 8. What's NOT done — recommended priority order

### Tier 1 — close existing gaps

| Item | Effort | Why |
|---|---|---|
| **Fix the FancyZones AX bug** (see §6) | < 1 hr after user grants permission | Blocks the entire snap feature |
| **EventKit edit/create for non-Google calendars** | ½ day | Today Forge can only round-trip Google events. iCloud/Outlook/Exchange users see read-only. EventKit supports `EKEvent.save(eventStore:span:)`. |
| **Google OAuth verification submission** | 30 min setup, ~3 wks Google review | See §10 — required for public distribution |

### Tier 2 — substantial new modules (already scoped)

| Module | Effort | Notes |
|---|---|---|
| **aText-style text expander** | ~2 days | Reuse existing `KeyRemapModule` CGEventTap. Snippet store on SettingsManager. Trigger detection via rolling char buffer; synthesize Backspace × trigger.length then post expansion via `CGEvent.keyboardSetUnicodeString`. Placeholders: `{date}`, `{time}`, `{clipboard}`, `{cursor}`. Per-app whitelist/blacklist scope. |
| **Loom-style screen recording** | ~2 days | `SCStream` (ScreenCaptureKit, macOS 12.3+) → `AVAssetWriter` H.264 MP4 at 1080p30. Optional mic + webcam corner. 5-min cap via Timer. Upload to catbox.moe (existing pipe in screenshot module supports MP4 up to 200MB). Suggested shortcut: ⌃⌥⇧R. |
| **Free unlimited AI via Ollama** | ~1 day | Detect `http://localhost:11434`. If absent, show "Install Ollama" CTA that runs `brew install ollama && ollama pull llama3.2:1b`. After that every AI call is free + offline. Foundation for: smart-paste expansion in clipboard history, calendar event parsing improvements, screenshot text summaries. |

### Tier 3 — polish + future-proofing

| Item | Effort | Why |
|---|---|---|
| **Bundle ID rename** (`com.strativ` → `com.kahar` or chosen) | 30 min | See §10. User explicitly deferred this. Touches `project.yml` (3 lines), `Info.plist` (2 lines), `GoogleCalendarService.swift` (2 lines). Side effect: needs Accessibility re-grant + Google OAuth tokens re-fetched. |
| **Per-monitor FancyZones preferences** | ~1 day | `defaultHorizontal` / `defaultVertical` stars are persisted but ignored at snap time. Needs a real per-monitor data model: `[NSScreen.id → ActiveLayout]` instead of one global `activeLayoutRef`. |
| **Workspaces** (`WindowManagerModule.saveCurrentWorkspace` / `launchWorkspace`) | ~1 day | Backend wired, no UI. Add a settings panel for "Save current arrangement as workspace X" + named list. |
| **Mouse Highlight crosshairs** (`crosshairsEnabled`) | ~½ day | Module supports it, no UI toggle. Add to Settings → Shortcuts → Mouse & Highlights group, or a separate Settings section. |

---

## 9. Distribution + OAuth strategy

Forge ships with a bundled Google OAuth Client ID (`GoogleCalendarService.defaultClientID`) under `com.strativ.forge`'s Cloud project. Google's rules:

| State | Who can sign in | Action |
|---|---|---|
| **Testing** (current) | Up to 100 emails I whitelist | Add them in Google Cloud Console → OAuth consent screen → Test users |
| **Published — unverified** | Anyone, but Google shows a scary "unverified app" interstitial | Just flip the toggle |
| **Published — verified** | Anyone, clean consent screen | Submit verification (free, ~3 weeks) |

The `auth/calendar` scope is "sensitive" but NOT "restricted" — no paid CASA audit needed.

### To go public:
1. Set up a privacy policy URL + Terms of Service URL.
2. Record a ~30s screencast of Forge's OAuth flow (host on YouTube).
3. Submit in Google Cloud Console → OAuth consent screen → "Submit for verification".

The `SettingsManager.clientID` override field already exists for power users who want their own Client ID.

---

## 10. Bundle ID rename — to-do list when triggered

User asked about renaming `com.strativ.forge` to something else (e.g. `com.kahar.forge`, `se.strativa.forge`). Six file locations to update:

| File | Line | Change |
|---|---|---|
| `project.yml` | 3 | `bundleIdPrefix:` |
| `project.yml` | 25 | `PRODUCT_BUNDLE_IDENTIFIER:` (main target) |
| `project.yml` | 57 | `PRODUCT_BUNDLE_IDENTIFIER:` (tests target) |
| `Forge/Resources/Info.plist` | 10, 56 | `<string>com.strativ.forge</string>` (twice) |
| `Forge/Sources/Modules/GoogleCalendar/GoogleCalendarService.swift` | 1126 | `private static let service = "com.strativ.forge.google"` |
| `Forge/Sources/Modules/GoogleCalendar/GoogleCalendarService.swift` | 1209 | `DispatchQueue(label: "com.strativ.forge.oauth-loopback")` (cosmetic) |

Then `xcodegen generate && xcodebuild ... build`.

**Side effects to communicate:**
- All Accessibility / Screen Recording permissions need re-granting (keyed to bundle ID).
- Existing Google OAuth tokens become inaccessible (Keychain entries under old service string). User has to reconnect Google accounts. UserDefaults migration optional: `cp ~/Library/Preferences/com.strativ.forge.plist ~/Library/Preferences/com.NEW.forge.plist`.
- Bundled OAuth Client ID still belongs to my Cloud project unless they create their own.

---

## 11. Memorable patterns + gotchas

1. **`open path/to/Forge.app`** caches state. If the running binary looks wrong (logs in old format, etc.), `killall -9 Forge` first.
2. **`xcodegen generate`** after every new file. Build will error out otherwise.
3. **Code-sign churn** invalidates Accessibility / Screen Recording trust. Tell the user to toggle Forge off+on in Privacy & Security after a fresh build if AX features stop working.
4. **`@MainActor`-isolated closures**: SwiftUI Button's `action:` is `@MainActor () -> Void` — passing a function with parameters fails. Use `Button { someFunc() } label: { ... }` instead of `Button(action: someFunc)`.
5. **`isFlipped: Bool`** on a custom NSView is the cleanest way to switch to top-left origin matching SwiftUI/web convention.
6. **`NSAlert.runModal()`** spawns at `.modalPanel` level (8). If your overlay is at `.screenSaver` (1000), drop your overlay's `window.level = .normal` before calling runModal, then restore. Or bump `alert.window.level = .init(rawValue: .screenSaver.rawValue + 1)`.
7. **`NSWindow(borderless:)`** defaults to `canBecomeKey = false`. To accept keyboard input on a borderless panel, subclass `NSPanel` and override `canBecomeKey` + `canBecomeMain` to return `true`.
8. **`NSPanel(.nonactivatingPanel)`** + subview buttons: override `acceptsFirstMouse(for:)` to return `true` on both the panel's content view AND each clickable subview, otherwise the first click only activates the window and the button needs a second click.
9. **NSEvent.addGlobalMonitorForEvents** fires only for events delivered to OTHER apps. For events on Forge's own windows, add a LOCAL monitor in parallel.
10. **SwiftUI `ScrollView` inside `NSPopover` swallows scroll wheel events.** Use `ScrollableContainer` (NSScrollView shim) for vertical scrolling and `DragGesture`-driven offset for horizontal.

---

## 12. Just-tell-me-the-build commands

```bash
# Bootstrap a fresh session
cd /Users/strativa/Desktop/macos-app

# After editing source files
xcodegen generate
xcodebuild -project Forge.xcodeproj -scheme Forge -configuration Debug \
    -destination 'platform=macOS' build

# Force-restart Forge
killall -9 Forge 2>/dev/null; sleep 1
open ~/Library/Developer/Xcode/DerivedData/Forge-blnasyzzqiuxoqcargwjyxmxzufk/Build/Products/Debug/Forge.app

# Debug FancyZones AX
rm -f ~/Library/Logs/Forge/fancyzones.log
tail -f ~/Library/Logs/Forge/fancyzones.log

# Confirm running binary is fresh
pgrep -lf "Debug/Forge.app/Contents/MacOS/Forge"
```

---

## 13. User context — who is this for?

- **Strativ** — Swedish IT consultancy, offices in Stockholm + Dhaka.
- Team email: `team-design@strativ.se`.
- Brand: Strativ red (`#E72903` — the Forge accent), Expletus Sans + Inter typography.
- The app is being built as an internal tool for the design team, with intent to eventually distribute publicly (hence the OAuth verification path).
- Today's working date during session: 2026-05-25.

---

## 14. Sentinel state at handoff

- Last build: **SUCCEEDED** (clean build, all features compile).
- Last running PID: 19642 from Debug build path.
- Open bugs: **1** (FancyZones AX permission — see §6).
- Open feature requests: **3** (text expander, screen recording, Ollama AI — see §8 Tier 2).
- Bundle ID: still `com.strativ.forge` (rename deferred).
- Google OAuth: still in Testing state with bundled Client ID.

---

> Hand this file to a fresh Claude session as the very first message, along with whatever the next ask is. Everything above is current as of the session-end snapshot — file paths, line numbers, conventions, in-flight bugs.
