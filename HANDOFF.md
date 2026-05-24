# Forge — Project Handoff

Last updated: 2026-05-24

## What Forge is

A macOS menu-bar utility that combines Dot's calendar aesthetic with the
PowerToys-style grab bag of productivity modules. SwiftUI + AppKit, single
target, deployment min macOS 14.

- Repo path: `/Users/strativa/Desktop/macos-app/`
- Git remote: `github.com/iknahar/forge`
- Bundle id: `com.strativ.forge`
- Build: `xcodebuild -project Forge.xcodeproj -scheme Forge -configuration Debug -destination 'platform=macOS' build`
- Project regen (if `project.yml` changes): `xcodegen generate`

## Architecture cheat sheet

```
Forge/Sources/
├── App/                  AppDelegate (menu bar render, hotkeys, popover)
├── Core/                 ModuleRegistry, SettingsManager, ScrollableContainer,
│                         OverlayWindow, HotkeyManager, ShortcutBinding
├── Design/               ForgeTheme (adaptive light/dark tokens),
│                         ForgeComponents (buttons, pills, sections)
├── Modules/
│   ├── Calendar/         CalendarModule + popover view + FullCalendarView window
│   ├── GoogleCalendar/   GoogleCalendarService (OAuth loopback + REST)
│   ├── CommandPalette/   Command bar (currently hidden from UI per design)
│   ├── WindowManager/    Always-on-top, screenshots, etc.
│   ├── ColorPicker/      Magnifier-loupe color picker (OverlayWindow)
│   ├── ScreenRuler/      Pixel ruler overlay (OverlayWindow)
│   ├── TextExtractor/    Vision OCR rect grab (OverlayWindow)
│   ├── ZoomIt/           Magnifier + draw tool (OverlayWindow + toolbar)
│   ├── FancyZones/       Snap zones — UI stub only, no actual snapping yet
│   ├── KeyRemap/         Data + CGEventTap exist, NO UI to edit mappings
│   ├── MouseHighlight/   Red animated spotlight, 3s auto-dismiss, ESC dismiss
│   ├── MeetingReminder/  Floating banner OR fullscreen alert (toggle in settings)
│   └── Screenshot/       Lightshot-style: select → in-place annotate → upload
└── UI/                   MenuBarView (popover), SettingsView (Preferences window)
```

### Key patterns

- **Module enable/disable** flows through `ModuleRegistry.enabledStates`
  (`@Published [String: Bool]`) so toggles propagate. Don't mutate
  `module.isEnabled` directly.
- **Adaptive colors**: every token in `ForgeTheme.Colors` uses
  `NSColor(name:dynamicProvider:)` so light/dark flips automatically.
- **Scroll in popover**: SwiftUI `ScrollView` drops wheel events inside
  `NSPopover` on Sonoma+. Use `ScrollableContainer` (NSScrollView wrapper
  around an `NSHostingController` with `sizingOptions = [.preferredContentSize]`).
- **Overlay windows that need ESC / keyDown** (ZoomIt, Screen Ruler, Color
  Picker, Text Extractor, Screenshot, fullscreen meeting alert) use the
  `OverlayWindow` `NSPanel` subclass which overrides `canBecomeKey = true`.
- **Global hotkeys**: `HotkeyManager` (Carbon API). Local ESC also uses
  `NSEvent.addLocalMonitorForEvents` as a belt-and-suspenders fallback.

## Google Calendar OAuth — important context

- It's a **Desktop OAuth client** (Installed app). Custom URL schemes are
  rejected, so the flow uses an `http://localhost:PORT` loopback redirect
  via `NWListener`.
- Bundled `client_id` AND `client_secret` are checked in — Google requires
  the secret even for PKCE Installed apps. Both live in
  `GoogleCalendarService.swift`.
- The Google project is still in "Testing" — adding new users requires
  adding their Gmail to **Test users** in the Cloud Console OAuth consent
  screen. Production verification has not been requested yet.
- Two-phase add flow: `exchange()` saves tokens + a `pendingAccount`, then
  the `GoogleColorPickerSheet` confirms a color and we save the account.
  The chosen color is tied to **every** event from that account.

## Most recent session: what just shipped

1. **Lightshot-style screenshot flow** — `ScreenshotAnnotateModule.swift`
   was rewritten. `LightshotOverlayView` handles selection + annotation in
   one window; captured pixels stay frozen at the original spot.
   `LightshotToolbar` (SwiftUI) floats below selection. Export: copy /
   save / catbox.moe upload.
2. **Popover left/right padding** reduced to ~1/3 of `lg` (16pt → 5pt).
   Affects header / calendar / tools list / module rows / footer in
   `MenuBarView.swift`.
3. **Settings layout**: window 960 → 1020, preview pane 320 → 280,
   horizontal padding 28 → 20. Fixes content getting clipped on Calendar
   and Menu Bar tabs.
4. **Token chip grid** now `.frame(maxWidth: .infinity, alignment: .leading)`
   so chips wrap to multiple lines (no more cut-off "World").
5. **MiniCalendarPreview** in the Calendar tab preview pane shows only the
   first 2 world-clock cities with `.lineLimit(1)` — no more "Stockhol\\nm"
   wrap inside the 280pt preview.
6. **WorldClockEditor** time pill now uses
   `.fixedSize(horizontal: true, vertical: false)` so "19:52" can never
   truncate to "19:5…".

## What's done across the project

- **Dot-style popover**: header, pill tabs, mini calendar with week numbers,
  weekend dim, week-start option, today highlight, event dots, day/year
  progress strips, world clock strip, footer.
- **Full Calendar window** (Notion-Calendar-style): hour grid, click empty
  slot → `NewEventSheet`, account picker, Google API create-event.
- **Google OAuth** end-to-end: loopback redirect, PKCE + bundled secret,
  keychain token storage, calendar list + events fetch, dedup against
  EventKit, internal per-account color.
- **EventKit integration**: native iCloud / Google / Outlook events surface
  through EventKit automatically. Google events come through Google API
  for richer metadata (color, calendar source).
- **Meeting Reminder** module with floating glass banner OR fullscreen
  alert. Fullscreen has built-in cyan-stripe background or user-picked
  image. Configurable lead time. ESC dismisses.
- **Mouse Highlight** with red animated radial gradient, follows cursor,
  3s auto-dismiss, ESC dismiss, ⇧⌘M shortcut.
- **Screenshot** (⌃⌥S): Lightshot-style select + annotate + catbox upload.
- **ZoomIt, Screen Ruler, Color Picker, Text Extractor**: all overlays
  responsive to ESC via `OverlayWindow`.
- **Settings UI**: 7 tabs (General, Modules, Calendar, Windows, Menu Bar,
  Shortcuts, About) with per-tab live preview pane on the right.
- **Menu Bar composer**: 12 tokens (icon, date, time, next event,
  countdown, week, day%, year%, world clock, time-left, events-left,
  focus-time), custom time format, separator picker.
- **Adaptive dark mode** across the whole app via dynamic NSColor tokens.
- **Reliable scroll wheel** in popover + settings via NSScrollView wrapper.

## What's NOT done — priority order for next session

### High priority

1. **KeyRemap end-to-end UI** — the module has a working `CGEventTap` and a
   data model for mappings, but there's no UI to add/edit/remove a
   key → key remap. Needs:
   - A settings card under Modules (or its own tab) listing existing
     mappings with delete buttons.
   - A "+ Add mapping" row that captures source key, then target key.
   - Persistence via `SettingsManager`.
   - Live enable/disable from the row.

2. **FancyZones actual snapping** — currently the UI stub shows zone
   templates but dragging a window does nothing. Needs:
   - Global mouse-drag listener to detect Shift+drag (or modifier of
     choice).
   - Display zone overlay during drag.
   - On release, resize/position the dragged window via Accessibility API
     (`AXUIElement`) to fill the chosen zone.
   - Save user-customized zone layouts.

3. **Edit / delete Google events** — `GoogleCalendarService.createEvent`
   works. Add `updateEvent` (PATCH `/events/{id}`) and `deleteEvent`
   (DELETE) so the calendar UI can offer "Reschedule" / "Cancel" / "RSVP
   with note" actions on the event detail popover.

### Medium priority

4. **Camera preview before meetings** — toggle in Meeting Reminder card.
   Needs `AVCaptureSession` preview on the fullscreen alert so the user
   can check their camera before joining.
5. **Natural-language event creator** — "Lunch tomorrow at 1" → parsed
   `CalendarEvent`. Use `NSDataDetector` or `DateParser`. Wire to the
   Command Palette and the `+` button in FullCalendarView.
6. **Mark This Date** — quick-action to drop a colored marker on a date
   in the mini calendar (anniversaries, deadlines). Persist in
   `SettingsManager`.
7. **Floating banner positioning options** — currently bottom-center.
   Offer top-right / top-center / bottom-right presets.

### Low priority / nice-to-have

8. **Google verification** — when ready for unlimited users, submit the
   OAuth consent screen to Google. App requires verified domain + scope
   justification. (This is a console task, not code.)
9. **Microsoft Calendar** + **Exchange/Outlook native** OAuth — currently
   only Google has direct API integration; M365 events still come through
   EventKit. A native Microsoft Graph client would mirror the Google flow.
10. **Linked Calendars UI restoration** — section was removed at user's
    request but might come back when M365 integration lands.
11. **App icon + DMG packaging** for distribution outside the dev build.

## Known gotchas

- `SettingsManager` is the source of truth for almost everything user-
  configurable. Adding a new setting? Add the `@Published` property +
  defaults migration if needed.
- `ShortcutBinding.allActions` is the master list of bindable shortcuts.
  Adding a hotkey to a module? Append here, then handle in
  `AppDelegate.setupShortcuts()`.
- Don't reintroduce a duplicate `Color(hex:)` extension — it lives in
  `ForgeTheme.swift` and is referenced everywhere.
- `Forge.entitlements` (NOT `.entitlements.xml`) — make sure
  `project.yml` and disk filename match.
- `xcodegen generate` will overwrite the `.xcodeproj`. Source-of-truth is
  `project.yml`.

## Notes for the next agent

- The user is on the Strativ design team
  (`team-design@strativ.se`). They iterate visually with screenshots
  and care a lot about pixel-perfect Dot parity.
- They prefer concrete fixes over discussions. When in doubt, build and
  show, then iterate.
- Common request pattern: numbered list of issues with annotated
  screenshots. Match the numbering in the response.
- Build verification is non-negotiable after structural changes — always
  run `xcodebuild ... build` and confirm `** BUILD SUCCEEDED **`.
