import AppKit

extension NSWindow {
    /// Drags the window from a mouse-down, or on a double-click does what a title bar
    /// double-click does (System Settings → Desktop & Dock: zoom, minimize or nothing).
    func moveOrZoom(_ event: NSEvent) {
        guard event.clickCount == 2 else { return performDrag(with: event) }
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": miniaturize(nil)
        case "None": break
        default: zoom(nil)
        }
    }
}

/// Along the top edge while the sidebar is hidden: the window's only grip.
@MainActor
final class WindowDragStrip: NSView {
    override func mouseDown(with event: NSEvent) { window?.moveOrZoom(event) }
    override var mouseDownCanMoveWindow: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}

/// The window's left edge while the sidebar is hidden. The pointer reaching it peeks the
/// sidebar; clicks pass through to the page.
@MainActor
final class EdgeView: NSView {
    var onEnter: () -> Void = {}

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onEnter() }
}
