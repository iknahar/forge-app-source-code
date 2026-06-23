# Forge — Session Handoff & Plan

> Living handoff so a fresh session can resume without losing context.
> **Last updated after shipping v1.0.14.** Current released version: **1.0.14**.
> Build machine is on **macOS 26.5.1** (matters — see capture notes).

---

## 1. What Forge is

Native **macOS menu-bar productivity app** (SwiftUI + AppKit). Menu-bar only
(`LSUIElement` / `.accessory`, no Dock icon). Bundle id **`com.toolkit.forge`**.
~18 modules (Calendar, Google Calendar, Screenshot, Window Manager, FancyZones,
Color Picker, Screen Ruler, Text Extractor, ZoomIt, Key Remap, Mouse Highlight,
Meeting Reminder, Clipboard, Text Expander, Launchers, Claude Code launcher,
Eye Care, Ambient Sound).

Distribution is **free / no Apple Developer account** → **ad-hoc signed**, not
notarized. First launch on any Mac shows the Gatekeeper "unidentified developer"
prompt (right-click → Open, or `xattr -dr com.apple.quarantine /Applications/Forge.app`).

---

## 2. The three repos (all owned by GitHub user `iknahar`)

| Purpose | Local path | Remote |
|---|---|---|
| **Source code** | `/Users/strativa/Desktop/macos-app` | `github.com/iknahar/forge-app-source-code` |
| **Homebrew tap** | `/Users/strativa/Desktop/homebrew-forge` | `github.com/iknahar/homebrew-forge` (`Casks/forge.rb`) |
| **Landing page** | `/Users/strativa/Desktop/landing` | `github.com/iknahar/forge-landing-page` → deploys to `forge-toolkit.vercel.app` |

Install command (kept as the 3-part one-liner — the 2-part `iknahar/forge` is
impossible in Homebrew): `brew install --cask iknahar/forge/forge`

### ⚠️ GitHub auth gotcha
`gh` CLI has **two accounts**: `iknahar` (correct) and `nahar-strativ`. If the
active account flips to `nahar-strativ`, pushes/releases to these repos **403**.
Fix: `gh auth switch -u iknahar` before pushing.

---

## 3. Build & release workflow

**Source of truth:** `project.yml` (XcodeGen). `Forge.xcodeproj` is **gitignored**
and regenerated. `*.dmg` is gitignored; `dist/forge.rb` IS tracked.

**Dev iteration (per user's standing instruction — do NOT install a DMG each time):**
```bash
pkill -x Forge
xcodebuild -scheme Forge -configuration Debug -derivedDataPath build/DerivedData clean build
open build/DerivedData/Build/Products/Debug/Forge.app
```

**Full release pipeline (every version bump):**
1. Bump `Forge/Resources/Info.plist` → `CFBundleShortVersionString` + `CFBundleVersion`
   (do a **surgical text Edit**, NOT PlistBuddy — PlistBuddy reflows the file and strips comments).
2. Bump `project.yml` → `MARKETING_VERSION` + `CURRENT_PROJECT_VERSION`.
3. `xcodegen generate`
4. `./scripts/make-dmg.sh` → `dist/Forge-<version>.dmg` (reads version from Info.plist; Release build).
5. `shasum -a 256 dist/Forge-<version>.dmg`
6. Update **both** casks (`dist/forge.rb` + `homebrew-forge/Casks/forge.rb`) → new version + sha256.
7. Update landing: `app/page.tsx` (hero download href **+** the `v1.0.x · 4.5 MB …` version label) and `app/_components/Footer.tsx` (download href).
8. Commit + push `macos-app` `main`.
9. `gh release create v<version> dist/Forge-<version>.dmg --repo iknahar/forge-app-source-code --title "Forge <version>" --notes "…"`
10. Commit + push tap, commit + push landing.
11. **Verify**: `curl -sL <release dmg url> | shasum -a 256` matches the cask sha (allow a few seconds for CDN propagation — it can briefly 404 / mismatch right after upload).

**Signing config (project.yml `targets.Forge.settings.base`):**
```yaml
ENABLE_HARDENED_RUNTIME: NO
CODE_SIGN_IDENTITY: "-"                       # ad-hoc — portable across Macs
CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO        # no get-task-allow debug entitlement
```
Verify a build: `codesign -dvvv build/Release/Forge.app` → `Signature=adhoc`,
`codesign --verify --strict`, `lipo -archs` → `x86_64 arm64`.

Commit trailer in use: `Co-Authored-By: Claude …`.

---

## 4. Version history (what each release fixed)

- **Screenshot inline-text (early):** text now appears in exports; no cross-session
  leak; correct orientation (root cause: CGContext **implicitly flips Y** device→pixel,
  so a manual `scaleBy(y: -scale)` was a *double* flip → upside-down glyphs — removed it);
  multiple text blocks typable; overlay stays static.
- **1.0.3** — Ambient Sound module + ConfettiView; screenshot: I-beam cursor in text
  mode, **unique timestamped save filenames**; calendar/eye-care/meeting/google refinements.
- **1.0.4** — Google **keychain prompt storm** fixed via in-memory cache in `GoogleKeychain`.
- **1.0.5** — Signed with stable self-signed **"Forge Dev"** cert. *(Later reverted.)*
- **1.0.6** — Menu popover **light/dark flipping** fixed: `applyPopoverAppearance()` pins
  the popover's `NSAppearance` (adaptive `ForgeTheme.Colors` resolve against the window's
  appearance; a status-bar popover left unpinned inherited an unstable one).
- **1.0.7** — **Launch at login** implemented (`SMAppService` via `LaunchAtLogin.swift`;
  the toggle was previously a dead `.constant(false)`).
- **1.0.8** — **Reverted to ad-hoc signing** (self-signed cert crashed on other Macs);
  launch-at-login **default-on** + dependable two-way toggle (`userDisabled` flag so an
  explicit off sticks); **Google Meet "Join" opens under the event's own account**
  (`authuser=<email>` appended to `meet.google.com` links).
- **1.0.9** — **Google token moved out of the keychain → `0600` file**
  `~/Library/Application Support/Forge/google-tokens.json`. Keychain authorizes by code
  signature; ad-hoc changes per build → re-prompted forever on other Macs, and each
  prompt closed the transient popover ("crash") + blanked events. File store = no prompt
  ever. Silent non-prompting migration from old keychain (`kSecUseAuthenticationUIFail`).
  Also: `loadEvents()` no longer publishes the empty EventKit set mid-fetch.
- **1.0.10** — Default menu-bar tokens now **Icon · Ongoing · Next Event · Countdown**
  (matches landing mockup). Only affects fresh installs / un-customized users.
- **1.0.11** — `CalendarEvent.init(from: EKEvent)` **EventKit nil hardening**:
  `eventIdentifier`/`startDate`/`endDate` are IUOs and `calendar` is nonnull-but-nil for
  orphaned events → defaulted; `calendar` read via KVC. Only crashed on Macs with Calendar
  access granted (so never reproduced on the dev Mac, where it's denied).
- **1.0.12** — **Comprehensive crash-hardening sweep** (15 files): dynamic `URL(string:)!`
  built from event data → `guard`/throw; calendar date math `Calendar.date(...)!` → `?? fallback`;
  app-support `urls(...).first!` → `?? ~/Library/Application Support` (7 modules);
  `randomElement()!` → `?? default`. Left provably-safe ones (literal URLs,
  `String.data(using:.utf8)!`, AX `as!` on CF types that always succeed, `init(coder:)`).
- **1.0.14** — **Screen capture migrated to ScreenCaptureKit.** Root cause of the blank
  screenshots: `CGWindowListCreateImage` is deprecated and on macOS 14+/15/26 returns an
  **empty/transparent frame regardless of the Screen Recording grant** — which is why the
  1.0.13 alert *looped forever* (re-granting can't revive a dead API). `startCapture()` now
  uses `SCShareableContent.excludingDesktopWindows` + `SCScreenshotManager.captureImage`
  (`import ScreenCaptureKit`), excludes Forge's own windows (dropped the synchronous
  `hotkeyPreCapture` hack in AppDelegate), and keeps the 1.0.13 blank-frame guard as defense.
  **Confirmed working on macOS 26.5.1.** ⚠️ ColorPicker / ScreenRuler / TextExtractor / ZoomIt
  still use the legacy API → same migration pending (see §7.5).
- **1.0.13** — **Blank-capture detection.** After an update, macOS keeps a stale Screen
  Recording grant (`CGPreflightScreenCaptureAccess()` returns true) but the window server
  returns a **fully-transparent frame** → user annotates an invisible screenshot → export
  has only the drawings (white when pasted). `captureLooksBlank()` downsamples to 16×16 and
  checks alpha; a fully-transparent frame ⇒ show the permission alert (now worded for the
  "already enabled but stale → remove with – and re-add" case) instead of proceeding.

---

## 5. Hard-won technical facts (don't relearn these)

- **CGContext Y-flip:** device→pixel buffer is already flipped; never add manual negative-Y.
- **Self-signed cert is NOT for distribution:** only trusted on the machine that created it.
  It caused the "crashes on other Macs" reports (which were *actually* the 1.0.11 EventKit
  bug + 1.0.9 keychain prompts) — but as a rule, ship **ad-hoc**.
- **Keychain & TCC both key on code signature.** Ad-hoc changes the signature every build,
  so **Keychain "Always Allow", Screen Recording, and Accessibility grants are invalidated
  on every update** for every user. (Tokens now sidestep this via the file store; Screen
  Recording / Accessibility still don't.)
- `lsregister -kill` was removed by Apple; can't fully purge stale LaunchServices rows.
- `tccutil reset ScreenCapture com.toolkit.forge` resets the Screen Recording grant.
- AX values (`AXValue`/`AXUIElement`) are CF types → `as?` is a compile **error**
  ("always succeeds"); the `as!` is provably safe. Guard the *optional ref*, not the cast.
- Crash reports live in `~/Library/Logs/DiagnosticReports/` (and `…/Retired/`); EXC_BREAKPOINT
  = Swift trap (force-unwrap nil / precondition); EXC_BAD_ACCESS = memory.

---

## 6. Key files

| File | Role |
|---|---|
| `Forge/Sources/Modules/Screenshot/ScreenshotAnnotateModule.swift` | capture (`CGWindowListCreateImage`), annotate overlay, `renderAnnotatedSelectionPNG()`, `captureLooksBlank()` |
| `Forge/Sources/Modules/Calendar/CalendarModule.swift` | events, `loadEvents()`, `CalendarEvent.init(from:)` |
| `Forge/Sources/Modules/GoogleCalendar/GoogleCalendarService.swift` | OAuth, `GoogleKeychain` (now **file-backed**), API, Meet `authuser` |
| `Forge/Sources/Core/LaunchAtLogin.swift` | `SMAppService` login item + default-on policy |
| `Forge/Sources/App/AppDelegate.swift` | popover, `applyPopoverAppearance()`, `LaunchAtLogin.applyDefaultPolicy()` |
| `Forge/Sources/Core/SettingsManager.swift` | `menuBarTokens` default, `AppTheme` |
| `Forge/Sources/UI/SettingsView.swift` | settings UI incl. `LaunchAtLoginToggle`, Calendar tab |
| `project.yml` · `Info.plist` · `scripts/make-dmg.sh` · `BUILD.md` · `dist/forge.rb` | build/release |

---

## 7. Open items / pending decisions

1. **🔑 Signing for permission persistence (BIGGEST open decision).**
   As long as releases are ad-hoc, **every update invalidates Screen Recording / Accessibility /
   keychain grants for every user** (1.0.13 at least *detects* the screenshot case now).
   - Option A (free): re-adopt the stable **"Forge Dev"** self-signed cert for releases →
     grants survive updates on all Macs. The cert lives in the build Mac's login keychain
     (created earlier; leaf hash `96A62A54…`). Set `CODE_SIGN_IDENTITY: "Forge Dev"` (Release).
     *Caveat:* still triggers Gatekeeper "unverified" on other Macs (cert isn't Apple-trusted);
     only fixes *grant persistence*, not the first-launch warning. The reasons it was reverted
     in 1.0.8 (crashes / keychain prompts) are now fixed independently — so the original
     downside is gone.
   - Option B (paid, $99/yr): Apple **Developer ID + notarization** → no Gatekeeper warning
     **and** persistent grants. **User has declined paying.**
   - **STATUS: undecided.** User leaning free; revisit Option A.

2. **In-app crash reporter (offered, not built).** Users are non-technical and the maintainer
   can't access their Macs, so crash logs are unobtainable. Plan: catch uncaught exceptions +
   signals → write to `~/Library/Logs/Forge/crash.log`; on next launch show "Forge crashed last
   time — [Copy report]" so a user can paste it back. Would end the blind crash-guessing.

3. **Smooth selection drag (screenshot overlay).** Originally requested; the
   `setNeedsDisplay(dirtyRect)` optimization was reverted because the non-opaque overlay window
   doesn't preserve backing-store pixels on partial repaint. Proper fix = layer-backed
   compositing (separate dim + selection layers). **Not done.**

4. **Landing page:** Ambient Sound is intentionally **NOT** advertised (user's explicit call).
   Everything else has a feature card.

5. **Migrate the other capture tools to ScreenCaptureKit (RECOMMENDED next).** 1.0.14 fixed the
   Screenshot module, but **ColorPicker, ScreenRuler, TextExtractor, and ZoomIt still call the
   dead `CGWindowListCreateImage`** → they're almost certainly broken (blank/transparent) on
   macOS 14+/26 too. Screenshot used a one-shot `SCScreenshotManager.captureImage`; ColorPicker's
   loupe and ZoomIt sample pixels *continuously*, so those likely need an `SCStream` (live
   frames), not the one-shot API — more involved. User was told; **say-the-word follow-up.**

---

## 8. State of the dev Mac (important)

- Dev Mac is now on **1.0.14** in `/Applications` (reinstalled to verify the ScreenCaptureKit
  fix; the stale ScreenCapture grant was `tccutil reset` and re-granted — capture confirmed
  working). Note: each ad-hoc reinstall re-invalidates the Screen Recording grant, so after
  any future reinstall expect to re-grant once + relaunch.
- Google account connected for testing: `kamrun.nahar@strativ.se`.
- EventKit (native Calendar) access has been **denied** on the dev Mac for much of the session
  (why EventKit-only crashes never reproduced locally — they need access *granted*).

---

## 9. Quick "resume" checklist for a new session

1. `cd /Users/strativa/Desktop/macos-app`; confirm `gh auth status` active = **iknahar**.
2. Current version = check `Info.plist` `CFBundleShortVersionString` (should be ≥ 1.0.14).
3. To ship: follow **§3 release pipeline**. To iterate: **§3 dev iteration**.
4. If a user reports a crash you can't reproduce: it's almost always EventKit-granted +
   ad-hoc-signature + stale TCC. Consider building the **crash reporter (§7.2)**.
5. Biggest lever for the recurring "lost permissions after update" complaints: **§7.1**.
