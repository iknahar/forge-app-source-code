# Forge Recorder — FocuSee parity roadmap

Goal: match FocuSee's recorder + editor feature set. Status as of 2026-06-22.

## ✅ Done
- **Capture modes**: Full screen / Region (custom) / Window, multi-monitor picker. Polished FocuSee-style picker (mode cards + Device & Tool column).
- **Devices**: camera select, **microphone select + live mute**, **system-audio toggle** — chosen in the picker; camera-off + mic-mute toggles in the recording HUD.
- **Background**: wallpapers (12 macOS, default = 13-ventura-light), gradient presets, 4 colors, background blur, "None".
- **Zoom**: manual box zoom + auto-zoom-on-click, smooth ramp, live preview. Remembered zoom level.
- **Cut = Trim**: unified; cut anywhere; smooth composition playback.
- **Speed**: arbitrary value (any number) global + per-part regions. **Pitch-corrected** at non-1× (spectral).
- **Cursor**: enlarged synthetic pointer, styles, click effects (ring/ripple/spotlight/**sparkle**), hide-when-idle.
- **Spotlight / Blur**: dim/redact a region; FocuSee settings (mask opacity, roundness, feathering, strength) + Apply-to-all; **remembered** as defaults.
- **Camera**: webcam bubble → live (mirrored) → editor overlay → composited export. **Time-varying movement path** (record→editor→export). **White ring** in export. **Bubble / Fullscreen** layout. Move/hide live; on/off spans omitted from export.
- **Contextual inspector** (selected element's settings), mutually-exclusive selection, **only active-at-playhead effects render**, last-used settings remembered.
- **Teleprompter**: script entry in picker → floating auto-scroll panel during recording (recording-only, excluded from capture).
- **Coordinate origin**: region + secondary-display cursor/auto-zoom/avatar now land correctly (capture origin stored).
- **Frame**: padding, corner radius, shadow. **Export** to .mp4.

## 🔲 To build (FocuSee parity)
1. **Canvas aspect presets** (16:9/1:1/4:3/9:16) — renderer canvas rework, do FIRST (lower risk).
2. **Crop** (source sub-rect) — re-bases cursor/zoom/spotlight/blur coords; higher risk, own PR.
3. **Keystroke HUD** — capture keys (Input Monitoring permission), render shortcut pills; off-by-default (privacy).
4. **Click sound** — runtime-generated tick mixed into export at click times (needs composition-forcing refactor).
5. **Motion blur** — velocity-keyed; export parity needs a CoreImage compositor replacing the animation-tool path.
6. **AI avatar** — needs an external model/service; out of local scope (skip/stub).
7. **Timeline management** (toggle optional lanes) · **Share** (upload link).

## Notes / caveats
- **Verify**: mic audio + region blur survive export; record a test clip.
- Window mode: fixes the constant cursor offset, but does NOT track a window MOVED mid-recording (separate feature).
- Bundled Apple wallpapers = copyright call before public distribution.
- Recorder is local-only builds; nothing distributed yet.
