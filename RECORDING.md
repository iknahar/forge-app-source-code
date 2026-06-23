# Forge — Screen + Video Recording (Cursorful-style) — Design & Build Plan

Goal: a screen/region **video recorder** with cursor emphasis and the signature
**auto-zoom-to-cursor** post-production effect (à la Cursorful / Screen Studio).

Decided scope: **Full Cursorful-style** (all three phases). Build incrementally,
verify each phase, ship behind the existing module system (`ModuleCategory.screen`).

Foundation already in the repo:
- **ScreenCaptureKit** (added 1.0.14) — `SCStream` gives continuous frames.
- **Mouse Highlight** module — cursor spotlight + click rings (reuse for emphasis).
- **AVFoundation** familiarity (Ambient Sound) — `AVAssetWriter` for encoding.
- Min target macOS 14; SCK video + `AVAssetWriter` all supported there.

---

## Architecture

```
            ┌─────────────────────── RECORD ───────────────────────┐
 SCStream ──┤ video frames (CMSampleBuffer, BGRA)  ─► AVAssetWriter ─► raw .mov (full res)
 (display/  │ system audio (CMSampleBuffer)        ─►   (H.264/HEVC + AAC)
  region)   │ mic audio (AVCaptureDevice)          ─►
            └ interaction track (CGEventTap/global monitor): [{t, point, kind}] ─► sidecar .json
                                                                                         │
            ┌─────────────────── POST-PRODUCE (Phase 3) ───────────┐                     ▼
 raw .mov ──┤ AVAssetReader → per-frame:                          │  reads interaction track
            │   • virtual camera rect (auto-zoom easing)          │  → builds a keyframed
            │   • crop/scale to camera rect (Core Image / Metal)  │     "camera" timeline
            │   • composite styled cursor + click ripples         │
            │   • optional background pad + rounded corners       │
            └────────────────────────► AVAssetWriter ─► final .mp4/.mov
```

Key idea (how Screen Studio does it): **record raw + an interaction track, then
render the effects offline.** Offline = we can afford high-quality easing and
compositing without dropping frames during capture.

---

## Requested feature set (Loom / Screen Studio / Cursorful parity)
Recording **control bar** (floating, excluded from the capture): ● elapsed time,
**Pause/Resume**, **Stop**, restart, cancel. Pre-recording **options**: enlarged
cursor, show **keystrokes** (HUD), **Loom-style camera avatar** (circular webcam
bubble), mic on/off, region vs full screen. Post-record **edit** (trim, zoom
keyframes, background, reposition camera/keystroke HUD).

**Overlay strategy (important):** keystroke HUD, camera bubble, and the enlarged
cursor are shown as **on-screen overlay windows** so ScreenCaptureKit records them
live — *no per-frame compositing needed for Phase 2*. The trick: switch the SCK
filter from "exclude ALL Forge windows" to **exclude only the control bar + menu
popover** (by `SCWindow.windowID`), so the HUD/camera/cursor overlays appear in the
video but the controls don't. Phase 3's editor then repositions/zooms via offline
compositing.

## Phase 1 — Core recorder (MVP)  ← shipped-as-test; + pause/control bar this turn
- New module `ScreenRecorderModule` (`ModuleCategory.screen`).
- `SCStream` capturing the main display (BGRA `CMSampleBuffer`s).
- `AVAssetWriter` + `AVAssetWriterInput` (H.264, `.mov`) — append video buffers.
- System audio via `SCStreamConfiguration.capturesAudio` (macOS 13+); add a second
  `AVAssetWriterInput` (AAC) for it.
- Start/stop API; menu-bar + global hotkey (⌃⌥V) toggle; menu-bar recording indicator.
- Save to `~/Movies/Forge/Forge-Recording <timestamp>.mov` (timestamped, like screenshots).
- **Pause / Resume** (AVAssetWriter has no native pause → retime appended buffers by an
  accumulating `pauseOffset` via `CMSampleBufferCreateCopyWithNewTiming`, so paused time is
  removed, not frozen).
- **Floating control bar** (own NSPanel, excluded from capture): ● elapsed, Pause/Resume,
  Stop. Shown on start, closed on stop.
- Permissions: Screen Recording (have it); Microphone added in Phase 2.
- **Done = a real screen recording file you can play, with pause + controls.**

## Phase 2 — Overlays (live, captured by SCK) + region + mic
- **Enlarged cursor**: hide the system cursor (`config.showsCursor = false`) + draw an
  enlarged/smoothed cursor in a Mouse-Highlight-style overlay window that tracks the mouse.
- **Keystroke HUD**: capture keys via the KeyRemap/MouseHighlight event-tap infra → a
  floating "keys pressed" panel (KeyCastr/Screen-Studio style), shown as an overlay window.
- **Loom-style camera avatar**: `AVCaptureSession` webcam → circular floating bubble window
  (draggable, corner-snapping).
- **Capture scope (pre-record picker): Full screen / Region / Window.**
  * Full screen — current behaviour (`SCContentFilter(display:excludingApplications:)`).
  * Region — reuse the screenshot selection overlay to pick a rect → `SCStreamConfiguration.sourceRect`
    (+ width/height = rect × scale).
  * Window — list on-screen windows (`SCShareableContent.windows`) → pick →
    `SCContentFilter(desktopIndependentWindow:)`.
  Show the chooser before recording starts (small menu/popover from the menu-bar item).
- **mic narration** (`AVCaptureDevice`).
- Filter change: exclude only the **control bar + menu popover** by `windowID` so the
  HUD/camera/cursor overlays land in the recording but the controls don't.
- Each overlay is a user **toggle** (off by default).

## Phase 3 — Auto-zoom + post-production editor (the signature effect)
Built in three tested layers:

**3a — Interaction track (DONE this turn).** During record, an `InteractionRecorder`
samples cursor position (~60Hz, throttled) + left/right clicks + scroll via NSEvent
**global monitors** (mouse-only → no extra permission). Timestamps are in **active
time** (paused spans excluded, so they line up with the retimed video). On stop, a
sidecar **`<movie>.forgerec.json`** is written next to the `.mov` (screen size, scale,
events). Coords are `NSEvent.mouseLocation` (bottom-left origin) — 3b converts.

**3b — Auto-zoom render engine (next).** Compute a **camera timeline** from the track:
zoom IN toward clusters of clicks/activity, OUT on broad movement / idle; interpolate a
zoom+pan with spring/cubic easing. Render with **`AVMutableVideoComposition` + layer
`setTransformRamp(...)`** (time-varying scale/translate) → `AVAssetExportSession` — this
avoids a hand-rolled pixel pipeline. Optional: styled cursor, gradient background,
padding, rounded corners (those need a Core Image custom compositor).

**3c — Editor UI (after 3b).** Cursorful-style editor window:
- **Preview** + scrubber/**timeline** with playhead.
- **Segment toolbar** (matches Cursorful): **Add a segment**, **Split**, **Delete**,
  **Undo / Redo**, **Reset timeline**, zoom-the-timeline in/out.
- Per-segment effects, applied over a selected time range:
  - **Zoom** — MANUAL only (no auto-zoom by default). The user adds a zoom segment over a
    time range, then **draws a zoom BOX on the preview** (drag a rectangle) defining the area
    to zoom into. A box → scale = renderSize.w / box.w, focus = box center (normalized,
    top-left). The render eases into the box, holds, eases out (matches Cursorful). Segments
    are add / move / resize / delete on the timeline; the box is re-draggable on the preview.
    `ZoomPlanner` is kept only behind an optional **"Auto-zoom"** button, not applied by default.
  - **Speed** — speed up / slow down a range (time-remap via `scaleTimeRange`).
  - **Crop** — crop the frame to a sub-rect.
  - **Trim** — cut from start/end (and split-then-delete for the middle).
- **Background**: Gradient / **Image** / Solid (plain color) / Hidden (mirrors Cursorful), image blur,
  + rounded **browser frame** (Default/Minimal/Hidden), frame shadow + border, padding,
  aspect ratio (Native/16:9/9:16/1:1/4:3).
  * **Image backgrounds** come from a bundled set in `Forge/Resources/RecordingBackgrounds/`
    (ship presets) PLUS the user's own — a drop-in folder `~/Library/Application Support/Forge/Backgrounds/`
    and a "choose custom image…" picker. Editor lists bundled + user images as swatches; user can
    also pick a **plain color** or a gradient. (Requires extending `RenderOptions` with a background
    enum: `.gradient(top,bottom) | .solid(color) | .image(url, blur) | .hidden`, and the renderer to
    draw an image/solid background layer instead of only the gradient.)
- **Cursor**: enlarged size, smooth movement, shadow; **click animation** style.
- Export.

**Render (3b/3c shared).** `ZoomPlanner` (pure) turns the track → `[ZoomKeyframe]`
(t, scale, focus x/y). The renderer composites per frame:
`AVMutableVideoComposition` + **`AVVideoCompositionCoreAnimationTool`** — a parent layer
holds a **gradient/image background layer** + a **video layer** (cornerRadius, shadow,
padding) animated by a `CAKeyframeAnimation` (scale+position) built from the keyframes →
`AVAssetExportSession` (audio passes through). v1 of 3b may use the simpler
`setTransformRamp` (zoom only, no background) to de-risk; the CA-tool adds the background.

---

## Open considerations
- **Output format/size:** H.264 `.mov` default; HEVC option; configurable fps (default 60)
  and scale. Retina = large files — expose a "downscale to 1080p/1440p" toggle.
- **macOS 15+ shortcut:** `SCRecordingOutput` records straight to a file (simpler Phase 1),
  but we keep the `SCStream + AVAssetWriter` path for macOS 14 and because Phase 3 needs
  frame access anyway.
- **Performance:** real-time H.264 of a Retina display is fine via VideoToolbox (hardware).
  Phase 3 render is offline so it can take longer than the clip length.
- **Disk:** warn / show elapsed time + rough size; cap or chunk very long recordings.
