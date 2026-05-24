import SwiftUI
import AppKit

/// SwiftUI's `ScrollView` inside an `NSPopover` (and sometimes inside hosting
/// views) drops scroll-wheel events on macOS Sonoma+. Wrapping a real
/// `NSScrollView` is the canonical fix.
///
/// We use `NSHostingController` (not bare `NSHostingView`) because the
/// controller exposes `sizeThatFits(_ ProposedViewSize)` for properly
/// measuring SwiftUI content — bare `NSHostingView` doesn't.
struct ScrollableContainer<Content: View>: NSViewRepresentable {
    private let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    final class Coordinator {
        let controller: NSHostingController<AnyView>
        init(initialContent: AnyView) {
            controller = NSHostingController(rootView: initialContent)
            if #available(macOS 13.0, *) {
                // Only `.intrinsicContentSize` — NOT `.preferredContentSize`.
                //
                // We need the host view's intrinsicContentSize (height) to
                // track the SwiftUI content's natural height; otherwise
                // AutoLayout doesn't know how tall the document view is
                // and the scroll view ends up with the wrong content
                // bounds (the user saw the top of the list cut off, with
                // empty space below).
                //
                // We DON'T want `.preferredContentSize` because that
                // propagates up through NSPopover, which observes its
                // contentViewController's preferred size and animates the
                // outer popover to match — that was causing the popover
                // to visibly resize when an event row's natural width
                // changed (e.g. a Join button appearing).
                controller.sizingOptions = [.intrinsicContentSize]
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(initialContent: AnyView(content()))
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.verticalScrollElasticity = .automatic
        scroll.scrollerStyle = .overlay
        // Swap the default vertical scroller for our 10%-alpha subclass so
        // the scrollbar is barely visible while still being usable.
        scroll.verticalScroller = FadedScroller()
        // Scrollbar sits flush at the popover's right edge — no content
        // inset. Overlay style hides it when idle; while scrolling it
        // appears briefly at the edge and overlays the rightmost pixels,
        // which is the standard macOS behavior.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        let hostView = context.coordinator.controller.view
        hostView.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = hostView

        // Pin width to the scroll view's content area, accounting for the
        // trailing inset above. Top is anchored, bottom is left free so
        // the view can grow as tall as the SwiftUI content needs — that's
        // what gives NSScrollView something to scroll.
        NSLayoutConstraint.activate([
            hostView.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            hostView.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            hostView.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            hostView.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.controller.rootView = AnyView(content())
    }
}

/// `NSScroller` subclass that paints its knob + track at ~10% of the system
/// alpha — used so the popover scrollbar is barely visible.
///
/// We override the two drawing entry points (`drawKnob` and
/// `drawKnobSlot(in:highlight:)`) and wrap each `super` call in a CG state
/// that pushes alpha to 0.1. Setting `alphaValue` on the scroller alone
/// isn't enough because macOS animates it to 1.0 during a scroll fade-in.
final class FadedScroller: NSScroller {

    override static var isCompatibleWithOverlayScrollers: Bool { true }

    override func drawKnob() {
        guard let ctx = NSGraphicsContext.current?.cgContext else {
            super.drawKnob(); return
        }
        ctx.saveGState()
        ctx.setAlpha(0.1)
        super.drawKnob()
        ctx.restoreGState()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        guard let ctx = NSGraphicsContext.current?.cgContext else {
            super.drawKnobSlot(in: slotRect, highlight: flag); return
        }
        ctx.saveGState()
        ctx.setAlpha(0.1)
        super.drawKnobSlot(in: slotRect, highlight: flag)
        ctx.restoreGState()
    }
}
