import AppKit
import ApplicationServices

/// Floats a small lock badge over the Dock icon of every locked app
/// while App Lock is armed. The Dock belongs to macOS — we can't
/// touch its icons directly — so instead we query the Dock's
/// accessibility tree for each item's screen position and park tiny
/// borderless windows above the matching icons.
///
/// Positions refresh on a 2s timer: cheap (a handful of AX calls)
/// and tolerant of the Dock resizing, magnification, icons being
/// added/removed, or the Dock moving edges.
///
/// Requires the Accessibility permission Forge already requests for
/// window management. Without it, `dockItems()` returns nothing and
/// badges silently don't render — the lock itself is unaffected.
final class DockLockBadgeController {

    private var badgeWindows: [String: NSWindow] = [:]
    private var refreshTimer: Timer?
    private var bundleIds: Set<String> = []

    /// Begin badging the given apps. Safe to call repeatedly with an
    /// updated set (e.g. after the user edits the locked list).
    func start(bundleIds: [String]) {
        self.bundleIds = Set(bundleIds)
        refresh()
        guard refreshTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer.tolerance = 0.5
        refreshTimer = timer
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        for (_, w) in badgeWindows { w.orderOut(nil) }
        badgeWindows.removeAll()
        bundleIds.removeAll()
    }

    // MARK: - Refresh cycle

    private func refresh() {
        let items = Self.dockItems()
        var seen = Set<String>()

        for bid in bundleIds {
            // Resolve the app's install URL so we can match the
            // Dock item by path — titles are localized and less
            // reliable.
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid)
            else { continue }
            guard let frame = items[appURL.standardizedFileURL.path] else { continue }
            seen.insert(bid)
            placeBadge(for: bid, iconFrame: frame)
        }

        // Drop badges whose Dock icon vanished (app un-pinned + quit).
        for (bid, window) in badgeWindows where !seen.contains(bid) {
            window.orderOut(nil)
            badgeWindows.removeValue(forKey: bid)
        }
    }

    /// Snapshot of the Dock's items: absolute .app path → icon frame
    /// in AppKit screen coordinates.
    private static func dockItems() -> [String: NSRect] {
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return [:] }

        let dockEl = AXUIElementCreateApplication(dock.processIdentifier)

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(dockEl, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let dockChildren = childrenRef as? [AXUIElement]
        else { return [:] }

        // The Dock's first (and usually only) child is the icon list.
        var out: [String: NSRect] = [:]
        for list in dockChildren {
            var itemsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(list, kAXChildrenAttribute as CFString, &itemsRef) == .success,
                  let items = itemsRef as? [AXUIElement]
            else { continue }

            for item in items {
                var urlRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(item, kAXURLAttribute as CFString, &urlRef) == .success,
                      let url = urlRef as? URL
                else { continue }

                var posRef: CFTypeRef?
                var sizeRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &posRef) == .success,
                      AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &sizeRef) == .success
                else { continue }

                var pos = CGPoint.zero
                var size = CGSize.zero
                // swiftlint:disable force_cast
                AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
                AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
                // swiftlint:enable force_cast

                // AX coordinates are top-left-origin; AppKit windows
                // use bottom-left. Flip against the primary screen.
                guard let primary = NSScreen.screens.first else { continue }
                let appKitY = primary.frame.maxY - pos.y - size.height
                let frame = NSRect(x: pos.x, y: appKitY, width: size.width, height: size.height)

                out[url.standardizedFileURL.path] = frame
            }
        }
        return out
    }

    // MARK: - Badge windows

    private func placeBadge(for bundleId: String, iconFrame: NSRect) {
        let badgeSize: CGFloat = 22
        // Top-right corner of the icon, nudged slightly inward so
        // the badge overlaps the icon the way macOS's own badges
        // (e.g. the screen-sharing indicator) do.
        let origin = NSPoint(
            x: iconFrame.maxX - badgeSize + 4,
            y: iconFrame.maxY - badgeSize + 4
        )
        let rect = NSRect(origin: origin, size: NSSize(width: badgeSize, height: badgeSize))

        if let existing = badgeWindows[bundleId] {
            existing.setFrame(rect, display: true)
            existing.orderFrontRegardless()
            return
        }

        let window = NSPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // One notch above the Dock so the badge draws over the icon.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        // Clicks fall through to the Dock icon underneath — the
        // badge is purely informational.
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let host = NSHostingView(rootView: DockLockBadgeView())
        host.frame = NSRect(origin: .zero, size: rect.size)
        window.contentView = host
        window.orderFrontRegardless()
        badgeWindows[bundleId] = window
    }
}

// MARK: - Badge visual

import SwiftUI

/// The tiny lock chip drawn over a locked app's Dock icon. Styled
/// after macOS's own Dock badges: filled circle, white glyph,
/// hairline rim so it reads on any wallpaper.
private struct DockLockBadgeView: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Color(red: 0.85, green: 0.12, blue: 0.09))
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            Circle()
                .stroke(Color.white.opacity(0.85), lineWidth: 1.5)
            Image(systemName: "lock.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white)
        }
    }
}
