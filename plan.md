# Forge — Session Handoff & Plan

> Living handoff so a fresh session can resume without losing context.
> **Last updated after shipping v1.0.16.** Current released version: **1.0.16**.
> Build machine is on **macOS 26.5.1** (matters — see capture notes).
> Read §0 first if you're a fresh session — it's the fastest orientation.

---

## 0. TL;DR for a fresh session

- Forge = menu-bar macOS productivity app, ~19 modules, ad-hoc signed, free.
- The last several sessions built a **full screen/video recorder + FocuSee-style
  post-production editor** (`Forge/Sources/Modules/ScreenRecorder/` — ~10 files,
  the largest module). It shipped in **1.0.15**; **1.0.16** fixed an editor layout bug.
- Three repos: source (`macos-app`), Homebrew tap, landing page. Release = DMG on
  GitHub Releases + both casks + landing hrefs. Full pipeline in §3 — follow it exactly.
- Dev loop is **never** "install a DMG": kill Forge, build Debug, copy to
  /Applications, launch (§3). User's standing instruction.
- Biggest recurring pain: **every ad-hoc release invalidates the Accessibility /
  Screen Recording TCC grants** → clipboard paste, text expansion, window snap die
  silently after each update until re-granted (§7.1 has the fix options; §5 the debug trail).
- Open recorder backlog: canvas aspect presets + crop, keystroke HUD, click sound,
  motion blur (§7.6). Items awaiting user verification: mic-in-export, region blur
  in export (§7.7).
- User = Strativ design team. Brand accent **#FE5001** (`Color.forgeAccent` /
  `NSColor.forgeAccent`, defined in `CaptureScopePicker.swift`) — user calls it "red".
  Preferences in §9.

---

## 1. What Forge is

Native **macOS menu-bar productivity app** (SwiftUI + AppKit). Menu-bar only
(`LSUIElement` / `.accessory`, no Dock icon). Bundle id **`com.toolkit.forge`**.
~19 modules (Calendar, Google Calendar, Screenshot, **Screen Recorder**, Window
Manager, FancyZones, Color Picker, Screen Ruler, Text Extractor, ZoomIt, Key Remap,
Mouse Highlight, Meeting Reminder, Clipboard, Text Expander, Launchers, Claude Code
launcher, Eye Care, Ambient Sound).

Distribution is **free / no Apple Developer account** → **ad-hoc signed**, not
notarized. First launch on any Mac shows the Gatekeeper "unidentified developer"
prompt (right-click → Open, or `xattr -dr com.apple.quarantine /Applications/Forge.app`).

---

## 2. The three repos (all owned by GitHub user `iknahar`)

| Purpose | Local path | Remote |
|---|---|---|
| **Source code** | `/Users/strativa/Desktop/macos-app` | `github.com/iknahar/forge-app-source-code` (PUBLIC) |
| **Homebrew tap** | `/Users/strativa/Desktop/homebrew-forge` | `github.com/iknahar/homebrew-forge` (`Casks/forge.rb`) |
| **Landing page** | `/Users/strativa/Desktop/landing` | `github.com/iknahar/forge-landing-page` → deploys to `forge-toolkit.vercel.app` |

Install command (kept as the 3-part one-liner — the 2-part `iknahar/forge` is
impossible in Homebrew): `brew install --cask iknahar/forge/forge`

### ⚠️ GitHub auth gotcha
`gh` CLI has **two accounts**: `iknahar` (correct) and `nahar-strativ`. If the
active account flips to `nahar-strativ`, pushes/releases to these repos **403**.
Fix: `gh auth switch -u iknahar` before pushing.

### ⚠️ Cask divergence gotcha
`dist/forge.rb` (in source repo) and `homebrew-forge/Casks/forge.rb` are **NOT
identical files** — the tap version has `depends_on macos: :sonoma` and a different
desc/zap layout. When releasing, do a **surgical version+sha edit in each**; never
`cp` one over the other (that mistake was made and caught in-session).

### Note on `brew info` showing an old version locally
The dev Mac's local tap clone (under `$(brew --repository)/Library/Taps/…`) only
updates on `brew update`. If `brew info` shows a stale version but the remote
`Casks/forge.rb` is correct, end users are fine — run `brew update` locally.

---

## 3. Build & release workflow

**Source of truth:** `project.yml` (XcodeGen). `Forge.xcodeproj` is **gitignored**
and regenerated (`xcodegen generate` — REQUIRED after adding/removing source files).
`*.dmg` is gitignored; `dist/forge.rb` IS tracked.

**Dev iteration (per user's standing instruction — do NOT install a DMG each time):**
```bash
pkill -x Forge
xcodebuild -project Forge.xcodeproj -scheme Forge -configuration Debug \
  -derivedDataPath build/DerivedData \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
rm -rf /Applications/Forge.app
cp -R build/DerivedData/Build/Products/Debug/Forge.app /Applications/Forge.app
open /Applications/Forge.app
```

**Full release pipeline (every version bump):**
1. Bump `Forge/Resources/Info.plist` → `CFBundleShortVersionString` + `CFBundleVersion`
   (do a **surgical text Edit**, NOT PlistBuddy — PlistBuddy reflows the file and strips comments).
2. Bump `project.yml` → `MARKETING_VERSION` + `CURRENT_PROJECT_VERSION`.
3. `xcodegen generate`
4. `./scripts/make-dmg.sh` → `dist/Forge-<version>.dmg` (reads version from Info.plist; Release build).
5. `shasum -a 256 dist/Forge-<version>.dmg`
6. Update **both** casks (`dist/forge.rb` + `homebrew-forge/Casks/forge.rb`) → new version + sha256
   (surgical edits — see §2 cask divergence).
7. Update landing: `app/page.tsx` (hero download href **+** the `v1.0.x · 6.7 MB …` version label)
   and `app/_components/Footer.tsx` (download href). DMG is ~6.7 MB since the recorder shipped.
8. Commit + push `macos-app` `main`.
9. `gh release create v<version> dist/Forge-<version>.dmg --repo iknahar/forge-app-source-code --title "Forge <version>" --notes "…"`
10. Commit + push tap, commit + push landing.
11. **Verify**: `curl -sL <release dmg url> | shasum -a 256` matches the cask sha (allow a few
    seconds for CDN propagation — it can briefly 404 / mismatch right after upload).
12. Optionally install the Release build locally (replaces the Debug copy) and remind the user
    to **re-grant Accessibility** (§7.1 — every release invalidates it).

No git tags are used for versions (releases carry the version); `gh release create`
creates the tag implicitly.

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
- **1.0.13** — **Blank-capture detection.** After an update, macOS keeps a stale Screen
  Recording grant (`CGPreflightScreenCaptureAccess()` returns true) but the window server
  returns a **fully-transparent frame** → user annotates an invisible screenshot → export
  has only the drawings (white when pasted). `captureLooksBlank()` downsamples to 16×16 and
  checks alpha; a fully-transparent frame ⇒ show the permission alert (now worded for the
  "already enabled but stale → remove with – and re-add" case) instead of proceeding.
- **1.0.14** — **Screen capture migrated to ScreenCaptureKit.** Root cause of the blank
  screenshots: `CGWindowListCreateImage` is deprecated and on macOS 14+/15/26 returns an
  **empty/transparent frame regardless of the Screen Recording grant** — which is why the
  1.0.13 alert *looped forever* (re-granting can't revive a dead API). `startCapture()` now
  uses `SCShareableContent.excludingDesktopWindows` + `SCScreenshotManager.captureImage`
  (`import ScreenCaptureKit`), excludes Forge's own windows (dropped the synchronous
  `hotkeyPreCapture` hack in AppDelegate), and keeps the 1.0.13 blank-frame guard as defense.
  **Confirmed working on macOS 26.5.1.** ⚠️ ColorPicker / ScreenRuler / TextExtractor / ZoomIt
  still use the legacy API → same migration pending (see §7.5).
- **1.0.15** — **Screen/video recorder + FocuSee-style editor shipped** (the whole
  `Modules/ScreenRecorder/` tree — see §5 for architecture). ⚠️ Bundled Apple wallpapers
  are now in the public repo + DMG (user approved knowingly after being warned).
- **1.0.16** — Editor preview canvas **clipped to its column** (wallpaper/shadow/zoom/
  overlays were bleeding into the inspector strip); inspector is a solid full-height panel.
  Gotcha found: SwiftUI `.frame(width:maxHeight:)` mixing fixed+flexible params in one
  call = compile error; split into two `.frame` calls.

---

## 5. Screen Recorder module — full architecture (built in-session, 1.0.15/1.0.16)

The biggest module. Cursorful / Screen Studio / **FocuSee** class: record screen →
post-production editor → styled MP4 export. All files in
`Forge/Sources/Modules/ScreenRecorder/`.

### 5.1 Files & roles

| File | Role |
|---|---|
| `ScreenRecorderModule.swift` | Recording engine: SCStream capture → AVAssetWriter; scope cases (display/window/region); pause (retimed PTS); mic track; camera lifecycle; control-bar HUD; region-hint panel; teleprompter show/hide; sidecar write; opens editor on stop |
| `CaptureScopePicker.swift` | Pre-record picker (FocuSee-style, 760×480): 3 mode cards with wallpaper thumbnails (Full/Custom/Window), monitor picker, window list, Device & Tool column (camera/mic/system-audio dropdowns — "None" = off), teleprompter script sheet. Returns `(CaptureScope?, CaptureOptions?)`. Also defines `Color.forgeAccent`/`NSColor.forgeAccent` (#FE5001) + `RegionSelector` drag overlay |
| `InteractionRecorder.swift` | Global NSEvent monitors → `InteractionTrack` sidecar (`<movie>.forgerec.json`): cursor moves/clicks (`InteractionEvent`), avatar movement (`CameraKeyframe`), camera-off spans, **capture origin** (originX/Y — global bottom-left of recorded canvas). Active-time clock (paused time removed). ~60Hz throttle |
| `CameraCapture.swift` | Webcam AVCaptureSession → separate `<movie>.camera.mov` (mirrored, device selectable); `CameraBubblePanel` live draggable/resizable bubble (150px default) with `onGeometryChange` callback feeding keyframes |
| `RecordingEditor.swift` | THE EDITOR (~3700 lines). `EditorState` + all views. See §5.3 |
| `EditTimeline.swift` | Single source of truth for cuts+speed: `EditPiece`, `pieces()`, `composition()` (AVMutableComposition — carries **all** audio tracks), `insertEdited()` (aligns 2nd track e.g. camera), `sourceToOutput`/`outputToSource` time mapping |
| `RecordingRenderer.swift` | Export pass 1: AVVideoCompositionCoreAnimationTool layer tree (background/padding/corner/shadow, zoom keyframes, cursor, click effects incl. sparkle burst, spotlight, region blur, keystroke-ready patterns). `RenderOptions` struct carries everything |
| `CameraOverlayCompositor.swift` | Export pass 2 (only when camera): custom `AVVideoCompositing` — masks webcam to circle/rounded, per-frame position interpolation along recorded path, white ring, fullscreen layout, off-span omission. Carries all audio tracks through |
| `CursorGraphic.swift` | Synthetic pointer rendering (`arrowCG`), `CursorStyle` (dark/light/accent/dot), `ClickEffect` (none/ring/ripple/spotlight/**sparkle**) |
| `ZoomPlanner.swift` | Legacy auto-zoom keyframe planner (`ZoomKeyframe`); editor now uses click-cluster `autoZoom` instead but renderer still consumes keyframes |
| `TeleprompterPanel.swift` | Recording-only floating auto-scroll script panel (borderless Forge NSPanel → excluded from capture). Pause/speed/restart controls |

### 5.2 Recording pipeline

1. `startRecording()` → `CaptureScopePicker.present` → user picks scope + devices +
   optional teleprompter script (`CaptureOptions`).
2. Mic needs TCC: `AVCaptureDevice.requestAccess(for: .audio)` before `beginRecording`.
3. `beginRecording(scope:)` builds `SCContentFilter` **excluding all Forge windows**
   (that's why control bar / camera bubble / region hint / teleprompter never appear
   in the recording). Region mode sets `config.sourceRect`. `config.showsCursor = false`
   (synthetic cursor drawn later). `config.capturesAudio = systemAudioOn`.
   macOS 15+: `config.captureMicrophone` + `microphoneCaptureDeviceID` + a
   `.microphone` stream output → **separate mono AAC track** in the .mov.
4. Writer: H.264 video + AAC system-audio + optional AAC mic. All sample appends on
   one serial `outputQueue`. Pause = drop samples + fold gap into `pauseOffset`
   (subtracted from every later PTS — paused time is *removed*, not frozen).
5. Recording HUD (`RecorderControlBar`, 340px panel): dot + elapsed + pause +
   **camera on/off** (records off-spans → export omits avatar) + **mic mute**
   (drops buffers → silence) + stop.
6. Region mode also shows a persistent brand-red border (`RegionRecordingHint`,
   click-through panel) around the captured area.
7. On stop: finalize writer → write `InteractionTrack` sidecar → `RecordingEditor.open`.

Output files: `~/Movies/Forge/Forge-Recording <date>.mov` + `.forgerec.json` +
optional `.camera.mov`.

### 5.3 Editor (`RecordingEditor.swift`)

**Layout:** preview+timeline+toolbar LEFT, inspector RIGHT (300px, opaque,
full-height, clipped — user first asked left, then moved back right; keep right).
Root has `.tint(Color.forgeAccent)`, `.onDeleteCommand` (delete selected),
`.onExitCommand` (deselect).

**`EditorState`** (ObservableObject) owns:
- `segments: [ZoomSegment]` (aspect-locked box, start/end), `speedSegments`
  (arbitrary factor 0.1–10×), `cuts` (trim==cut, unified), `spotlights`
  (box + dim/roundness/feather), `blurs` (box + strength/roundness) — each with
  selected-ID; **selection is mutually exclusive** (`selectSegment/…` helpers clear
  others + `seekRequest` jumps playhead into the element's range so it's visible).
- Playback: plays an `EditTimeline.composition` (cuts removed, speed baked,
  `.spectral` pitch) — preview == export. Playhead kept in SOURCE time via
  `outputToSource`. Rebuild on `timelineRevision` bump.
- Camera: `cameraPath: [CameraKey]` (normalized from sidecar `CameraKeyframe`s the
  same way as cursor, so avatar lands where user had it live — this fixed the
  "avatar changed side" bug whose root cause was a hard-coded default position),
  `cameraFollowsPath` (drag in editor pins to fixed spot via `pinCameraToCurrent`),
  `cameraOffSpans`, `cameraLayout` (bubble/fullscreen), `cameraShape`.
- `autoZoom(from:)`: one editable ZoomSegment per click-cluster (0.8s merge gap,
  1.5s hold, box side = remembered zoom level).
- Undo: `EditSnapshot` covers all element arrays; drag coalescing via `beginEdit()`.

**Preview** (`PreviewContainer`): GeometryReader canvas — background wallpaper /
gradient / color (+ blur), video in `PlayerLayerView` (AVPlayerLayer + CALayer
cursor + click layer + region-blur `backgroundFilters` layer inside `PlayerNSView`
— cursor MUST be a CALayer, SwiftUI siblings render *under* AVPlayerLayer), zoom
box / spotlight / blur overlays, camera bubble. **Effects render only when playhead
∈ [start,end]** (user demand: "if the effect is not in action at that time, do not
show it"). All drags use `coordinateSpace(.named("forgePreview"))` — gestures
attached to a moving view drift (that was the "sloppy drag" bug). Whole canvas
`.clipped()` (1.0.16 fix). Live zoom during playback via scaleEffect+offset.

**Inspector** is contextual (FocuSee-style): selection shows ONLY that element's
panel + "‹ All settings" back-button; no selection = global sections (Background
tabs Wallpaper/Gradient/Color, Frame, Cursor, Camera, Motion, Speed). Selecting a
timeline block auto-scrolls (`ScrollViewReader` + `selectionAnchor`). Speed control
= typed TextField + stepper + preset chips (discrete commits — a continuous slider
would thrash timeline rebuilds).

**`RecorderDefaults`** (UserDefaults): last-used spotlight dim/roundness/feather,
blur strength/roundness, zoom box side — new effects adopt user's last settings.

**Timeline lanes:** zoom = brand red ("red hero"); cut/speed/spotlight/blur =
neutral gray with red selection border (user picked "Red hero, neutral rest").

### 5.4 Export

`renderOptions()` maps everything SOURCE→OUTPUT time (`EditTimeline.sourceToOutput`)
so effects stay in sync after cuts/speed. Pass 1 (`RecordingRenderer.render`) bakes
cosmetics via CoreAnimationTool; `export.audioTimePitchAlgorithm = .spectral`.
Pass 2 (camera only) = `CameraOverlayCompositor.overlay` — falls back to pass-1
output if it fails (export never breaks). Output `.mp4`.

### 5.5 Coordinate systems (the #1 source of recorder bugs)

- Sidecar events: **global screen points, bottom-left origin** (`NSEvent.mouseLocation`).
- `InteractionTrack.originX/Y` = global bottom-left of the recorded canvas —
  **subtracted** in `EditorState.init` norm() (fixes region/secondary-display offset;
  full-primary = (0,0) so unchanged). Window scope: fixes constant offset only —
  does NOT track a window moved mid-recording.
- Editor/normalized space: 0..1, **top-left** origin (`ny = 1 - y/sh`).
- Renderer slot / CoreImage: pixels, **bottom-left** (flip: `renderH - (cyTop + h/2)`).
- SCWindow/SCDisplay `.frame` = top-left global; NSScreen `.frame` = bottom-left global.

---

## 6. Hard-won technical facts (don't relearn these)

### App-wide
- **CGContext Y-flip:** device→pixel buffer is already flipped; never add manual negative-Y.
- **Self-signed cert is NOT for distribution:** only trusted on the machine that created it.
  Tried at 1.0.5, reverted at 1.0.8. Ship **ad-hoc**.
- **Keychain & TCC both key on code signature.** Ad-hoc changes the signature every build,
  so **Keychain "Always Allow", Screen Recording, and Accessibility grants are invalidated
  on every update** for every user. (Tokens sidestep via file store; Screen Recording /
  Accessibility still don't.)
- `lsregister -kill` was removed by Apple; can't fully purge stale LaunchServices rows.
- `tccutil reset ScreenCapture com.toolkit.forge` / `tccutil reset Accessibility
  com.toolkit.forge` reset grants (stale entries stack up — one per signature).
- AX values (`AXValue`/`AXUIElement`) are CF types → `as?` is a compile **error**
  ("always succeeds"); the `as!` is provably safe. Guard the *optional ref*, not the cast.
- Crash reports live in `~/Library/Logs/DiagnosticReports/` (and `…/Retired/`); EXC_BREAKPOINT
  = Swift trap (force-unwrap nil / precondition); EXC_BAD_ACCESS = memory.
- Clipboard paste debug log: `~/Library/Logs/Forge/clipboard-paste.log` — logs
  `AXIsProcessTrusted` per attempt. `false` = TCC problem, not a code bug. macOS
  **silently drops** synthesized CGEvents from untrusted processes.
- Chromium apps (Chrome, VS Code, Slack, Claude Desktop) need the FULL physical ⌘V
  stream (Cmd↓, V↓, V↑, Cmd↑) — a lone V-with-flag gets dropped.

### Recorder / AVFoundation
- **CALayer `filters`/`backgroundFilters` and CAEmitterLayer are NOT honoured by
  `AVVideoCompositionCoreAnimationTool`** offline render. Preview can use them
  (live layers); export needs CoreImage or layered-CALayer keyframe tricks.
  (Why region-blur export needs verification, and why sparkle = 8 dot layers.)
- CoreAnimationTool animation `beginTime` MUST be `AVCoreAnimationBeginTimeAtZero + t`
  — literal 0 is silently dropped.
- `EditTimeline.composition` must add a comp track **per source audio track** or the
  mic (2nd track) silently vanishes. Same in the camera pass-2 composition.
- `AVPlayerItem.audioTimePitchAlgorithm = .spectral` (preview) +
  `AVAssetExportSession.audioTimePitchAlgorithm = .spectral` (export) = pitch-correct speed.
- Custom compositor entry point is `startRequest(_:)` (not `startVideoCompositionRequest`).
- SCStream mic capture (`captureMicrophone`) is macOS 15+; gate with `#available`.
- SwiftUI gesture in a moving view = drifting drag; anchor with
  `DragGesture(coordinateSpace: .named(...))` on a stable ancestor.
- SwiftUI sibling views render UNDER a hosted AVPlayerLayer — overlays on video must
  be CALayers inside the NSView.
- Swift `guard` in a ViewBuilder body = compile error; use `if let`.
- Chat-attached images are NOT on disk — user must drop files into a folder.
- zsh `rm -f ./*.png` aborts the whole `&&` chain on no-match (glob error).
- xcodegen regenerate needed after adding files, else "cannot find X in scope".

---

## 7. Open items / pending decisions

1. **🔑 Signing / permission persistence (BIGGEST recurring pain).**
   Every ad-hoc release invalidates Accessibility + Screen Recording for every user.
   Bit the user 3× in-session (clipboard paste "broken" — was always
   `AXIsProcessTrusted = false`).
   - ~~Option A: self-signed "Forge Dev" cert~~ — **tried 1.0.5, reverted 1.0.8
     (crashed on other Macs). Do not re-ship self-signed to users.** (Could still be
     used for LOCAL dev builds only, keeping releases ad-hoc.)
   - Option B (paid, $99/yr): Apple **Developer ID + notarization** → persistent grants
     AND no Gatekeeper warning. **User has declined paying so far.**
   - Option C (cheap, recommended next): in-app `AXIsProcessTrustedWithOptions`
     prompt when a feature needs Accessibility and it's missing — macOS auto-lists
     Forge; re-grant becomes 2 clicks. Offered as "1.0.17", user hasn't said go yet.
2. **In-app crash reporter (offered, not built).** Catch uncaught exceptions/signals →
   `~/Library/Logs/Forge/crash.log`; on next launch "Forge crashed — [Copy report]".
3. **Smooth selection drag (screenshot overlay).** Reverted `setNeedsDisplay(dirtyRect)`
   optimization (non-opaque overlay window doesn't preserve backing store). Proper fix =
   layer-backed compositing. **Not done.**
4. **Landing page:** Ambient Sound intentionally NOT advertised (user's call).
   Recorder features not yet on the landing page either — worth adding cards.
5. **Migrate ColorPicker / ScreenRuler / TextExtractor / ZoomIt to ScreenCaptureKit.**
   Still on dead `CGWindowListCreateImage` → almost certainly blank on macOS 14+.
   Loupe/ZoomIt sample continuously → need `SCStream`, not one-shot.
6. **Recorder backlog (FocuSee parity — see `FOCUSEE_ROADMAP.md`, kept current):**
   - **Canvas aspect presets** (16:9/1:1/4:3/9:16) then **Crop** — renderer canvas
     rework; investigated in depth, plan exists (split into two phases; crop re-bases
     5 normalized coordinate systems — own PR). Renderer slot uses `.resizeAspectFill`
     vs preview `.resizeAspect` — must reconcile when canvas aspect ≠ recording aspect.
   - **Keystroke HUD** — global `.keyDown/.flagsChanged` monitor (precedent:
     MouseHighlightModule). Needs **Input Monitoring** TCC (no Info.plist key exists
     for it; prompt is system-generated). MUST be off-by-default (password privacy).
   - **Click sound** — runtime-generated tick (AVAudioPCMBuffer→AVAudioFile, no bundled
     asset) inserted per click at OUTPUT time; requires forcing the composition branch
     even for identity edits (raw-asset path can't take an inserted track).
   - **Motion blur** — export parity requires replacing CoreAnimationTool with a
     custom CoreImage compositor (XL); preview-only version is cheap.
   - **AI avatar** — needs external model/service; **skip** (out of local-only scope).
   - Timeline lane toggles; Share/upload link.
7. **Awaiting user verification (shipped, untested at runtime):**
   - Mic audio survives editing + export (2-track path).
   - Region blur visible in preview AND export (backdrop-filter caveat, §6).
   - Avatar position correct on region/secondary-display recordings.
   - Pitch at 2×, sparkle effect, fullscreen camera, teleprompter scroll.
8. **`RECORDING.md`** = original recorder design doc (pre-build). Architecture in §5
   supersedes it; keep for rationale.

---

## 8. State of the dev Mac (important)

- `/Applications/Forge.app` = **1.0.16 Release build**.
- **Accessibility grant was reset in-session** (`tccutil reset Accessibility
  com.toolkit.forge` — three stale entries cleared). Unless the user re-added Forge in
  System Settings → Privacy & Security → Accessibility, **clipboard paste / text
  expansion / window snap are still dead**. Verify via the paste log (§6).
- Screen Recording grant: was re-granted for 1.0.14-era; each reinstall invalidates —
  if captures come back blank, re-grant.
- Google account connected for testing: `kamrun.nahar@strativ.se`.
- EventKit (native Calendar) access **denied** on the dev Mac (why EventKit-only
  crashes never reproduced locally).
- `gh` active account must be **iknahar** (§2).

---

## 9. User preferences & working style (learned across sessions)

- **User:** Strativ design team (`team-design@strativ.se`), Swedish IT consultancy.
  Brand accent **#FE5001 (Strativ Orange)** — user says "red"; match "red and white
  branding" = forgeAccent + white/neutral chrome.
- **Dev loop:** never install DMGs during iteration — build Debug → copy to
  /Applications → launch (standing instruction).
- **Wire features fully:** new Forge modules must wire shortcut + menu display in all
  6 sites, not just the global hotkey (recorded memory).
- **Reference product:** FocuSee — user supplies screenshots, wants feature parity;
  "I actually want all of the features."
- **Editor UX rulings:** inspector on the RIGHT; contextual panel per selection;
  only show effects active at the playhead; remember user's last-tweaked settings;
  trim and cut are the same thing; arbitrary speed numbers (e.g. 3×) both global and
  per-part; default background = 6th wallpaper (13-ventura-light); smaller default
  avatar; preview canvas dark is fine (chrome follows system theme).
- **Wallpapers:** actual Apple macOS wallpapers bundled; user explicitly chose to
  publish them in the public repo + DMG after copyright warning (2026-06-23).
- Ships fast: version-per-fix, straight to `main`, no PRs/tags.
- Landing page must always list the current version + real DMG size.
- User expects "push/deploy everywhere" = source + GitHub release + BOTH casks +
  landing page, sha-verified (§3 steps 4–11) — not just `git push`.

---

## 10. Quick "resume" checklist for a new session

1. `cd /Users/strativa/Desktop/macos-app`; `gh auth status` active = **iknahar**.
2. Current version: `Info.plist` `CFBundleShortVersionString` (1.0.16 as of writing).
3. To iterate: §3 dev loop. To ship: §3 full pipeline (all 12 steps — user means ALL
   surfaces when they say "deploy everywhere").
4. Recorder work? Read §5 first — especially §5.5 coordinate systems and §6 AVFoundation
   facts. `FOCUSEE_ROADMAP.md` tracks feature status.
5. "X stopped working after update" (paste/expansion/snap/capture) → it's the ad-hoc
   TCC invalidation (§7.1). Check `~/Library/Logs/Forge/clipboard-paste.log` for
   `AXIsProcessTrusted = false`. Fix: re-grant; durable fix: §7.1 Option C.
6. If a user reports a crash you can't reproduce: EventKit-granted + ad-hoc + stale
   TCC. Consider the crash reporter (§7.2).
7. Next most-valuable work, in rough order: §7.1 Option C (permission prompt),
   recorder verification items (§7.7), canvas aspect presets (§7.6), ScreenCaptureKit
   migration for the 4 legacy tools (§7.5).
