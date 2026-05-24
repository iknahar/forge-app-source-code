import AppKit

/// Shared NSWindow subclass for all Forge overlay tools (ZoomIt, Screen Ruler,
/// Color Picker, Text Extractor, Mouse Highlight, Screenshot).
///
/// Two behaviors:
/// 1. Borderless `NSWindow` instances can't become key by default, so `keyDown`
///    never fires and ESC / hotkeys are dead — `canBecomeKey` fixes that.
/// 2. By default `NSWindow.constrainFrameRect(_:to:)` shrinks the frame to fit
///    inside the screen's *visible* area (which excludes the menu bar and the
///    dock). For full-screen overlays we explicitly want to cover the entire
///    physical screen, so we no-op the constrain.
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // Return the requested rect unchanged — don't auto-trim the menu bar
        // / dock area away. The caller (Screenshot module etc.) deliberately
        // passes the physical screen.frame.
        return frameRect
    }
}
