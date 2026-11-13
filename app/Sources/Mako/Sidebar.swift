import AppKit

private let pageDragType = NSPasteboard.PasteboardType("com.wego.mako.page")

extension NSColor {
    /// Trail colours by the core's slot. System colours, so each adapts to light and dark.
    static func trail(_ slot: Int) -> NSColor {
        let palette: [NSColor] = [.systemBlue, .systemOrange, .systemGreen, .systemPurple, .systemPink,
                                  .systemTeal, .systemYellow, .systemIndigo, .systemBrown]
        return palette[slot % palette.count]
    }
}

/// Where a dragged page lands relative to the row it is dropped on. Raw values are the core's.
enum DropPlace: String { case before, after, inside }

/// The trails list. It only draws rows and reports gestures; every rule lives in the core.
@MainActor
final class Sidebar: NSView {
    var onSelect: (UInt64) -> Void = { _ in }
    var onToggle: (UInt64) -> Void = { _ in }
    var onRename: (UInt64, String) -> Void = { _, _ in }
    var onClose: (UInt64) -> Void = { _ in }
    var onPlace: (_ page: UInt64, _ target: UInt64, DropPlace) -> Void = { _, _, _ in }
    var iconFor: (TrailRow) -> NSImage? = { _ in nil }

    private let stack = NSStackView()
    private var rowViews: [UInt64: RowView] = [:]
    private var generation = 0

    init() {
        super.init(frame: .zero)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityIdentifier("mako.sidebar")
        setAccessibilityLabel("Trails")
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(_ rows: [TrailRow]) {
        generation += 1
        let mine = generation
        // Removing a row that is being renamed ends its editing, which can save the name and
        // redraw from inside this loop. That newer redraw wins; this one stops.
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard mine == generation else { return }
        rowViews = [:]
        for (i, row) in rows.enumerated() {
            let view = RowView(row, endsTrail: rows.indices.contains(i + 1) ? rows[i + 1].depth == 0 : true, sidebar: self)
            rowViews[row.id] = view
            view.setIcon(iconFor(row))
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -12).isActive = true
        }
    }

    func beginRename(_ id: UInt64) { rowViews[id]?.beginRename() }

    /// Icons arrive after the rows are drawn; updating in place keeps a rename in progress.
    func refreshIcons() { rowViews.values.forEach { $0.setIcon(iconFor($0.row)) } }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One page in the sidebar: click to show it, double-click to rename, drag to move it
/// (with the pages beneath it) before, after, or inside another page.
@MainActor
private final class RowView: NSView, NSDraggingSource, NSTextFieldDelegate {
    let row: TrailRow
    private let icon = NSImageView()
    /// The last row of its trail: the rail's rounded bottom.
    private let endsTrail: Bool
    private unowned let sidebar: Sidebar
    private let label: NSTextField
    private var hovered = false { didSet { needsDisplay = true } }
    private var drop: DropPlace? { didSet { needsDisplay = true } }
    private var mouseDownAt: NSPoint?
    private var editor: NSTextField?

    init(_ row: TrailRow, endsTrail: Bool, sidebar: Sidebar) {
        self.row = row
        self.endsTrail = endsTrail
        self.sidebar = sidebar
        label = NSTextField(labelWithString: row.label)
        super.init(frame: .zero)

        let toggle = NSButton(title: row.hasChildren ? (row.collapsed ? "▸" : "▾") : "", target: self, action: #selector(toggled))
        toggle.isBordered = false
        // Kept in the row (not hidden) so pages without children still line up.
        toggle.isEnabled = row.hasChildren
        toggle.setAccessibilityElement(row.hasChildren)
        toggle.setAccessibilityIdentifier("mako.trail.\(row.id).toggle")
        toggle.setAccessibilityLabel(row.collapsed ? "Expand" : "Collapse")

        label.font = .systemFont(ofSize: 13, weight: row.active ? .semibold : (row.depth == 0 ? .medium : .regular))
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // The row itself is the accessibility element, not its text.
        label.setAccessibilityElement(false)

        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)

        for view in [toggle, icon, label] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            toggle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8 + CGFloat(row.depth) * 14),
            toggle.widthAnchor.constraint(equalToConstant: 14),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.leadingAnchor.constraint(equalTo: toggle.trailingAnchor, constant: 2),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        toolTip = row.url
        registerForDraggedTypes([pageDragType])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("mako.trail.\(row.id)")
        setAccessibilityTitle(row.label)
        setAccessibilityValue(row.active ? "selected" : "")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The site's icon, or a faint globe holding its place until one arrives.
    func setIcon(_ image: NSImage?) {
        icon.image = image ?? Self.globe
        icon.contentTintColor = image == nil ? .tertiaryLabelColor : nil
        setAccessibilityHelp(image == nil ? "no site icon" : "site icon")
    }
    private static let globe = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 12, weight: .light))

    override func accessibilityPerformPress() -> Bool {
        sidebar.onSelect(row.id)
        return true
    }

    @objc private func toggled() { sidebar.onToggle(row.id) }

    /// The row takes its own clicks; only the toggle and the name being edited take theirs.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit is NSButton || editor != nil ? hit : self
    }

    // MARK: Looks

    override func draw(_ dirtyRect: NSRect) {
        let color = NSColor.trail(row.color)
        let shape = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        if row.active {
            color.withAlphaComponent(0.2).setFill()
            shape.fill()
        } else if hovered || drop == .inside {
            NSColor.labelColor.withAlphaComponent(drop == .inside ? 0.16 : 0.07).setFill()
            shape.fill()
        }
        // One rail per trail down the leading edge, rounded only where the trail starts and ends.
        // It reaches across the 1 pt gap below so consecutive rows join up.
        let top = row.depth == 0, bottom = endsTrail
        let rail = NSRect(x: 0, y: bottom ? 3 : -1, width: 3, height: bounds.height - (bottom ? 3 : -1) - (top ? 3 : 0))
        color.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: rail, xRadius: top || bottom ? 1.5 : 0, yRadius: top || bottom ? 1.5 : 0).fill()
        if let drop, drop != .inside {
            NSColor.controlAccentColor.setFill()
            NSRect(x: 4, y: drop == .before ? bounds.maxY - 2 : 0, width: bounds.width - 8, height: 2).fill()
        }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    // MARK: Click, rename, context menu

    override func mouseDown(with event: NSEvent) { mouseDownAt = event.locationInWindow }

    override func mouseUp(with event: NSEvent) {
        guard mouseDownAt != nil else { return }
        mouseDownAt = nil
        if event.clickCount == 2 { beginRename() } else { sidebar.onSelect(row.id) }
    }

    /// Swaps the label for a text field. Enter saves, Escape or clicking away keeps the old name.
    func beginRename() {
        guard editor == nil else { return }
        let field = NSTextField(string: row.label)
        field.font = label.font
        field.delegate = self
        field.target = self
        field.action = #selector(renamed(_:))
        field.setAccessibilityIdentifier("mako.trail.\(row.id).name")
        field.setAccessibilityLabel("Page name")
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: label.leadingAnchor, constant: -2),
            field.trailingAnchor.constraint(equalTo: label.trailingAnchor),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        label.isHidden = true
        editor = field
        window?.makeFirstResponder(field)
    }

    // An empty name goes back to the page's own title; that rule is the core's.
    @objc private func renamed(_ field: NSTextField) {
        // Saving rebuilds the rows, which ends editing and would send this action a second
        // time from inside the rebuild.
        field.action = nil
        sidebar.onRename(row.id, field.stringValue)
    }

    private func endRename() {
        editor?.removeFromSuperview()
        editor = nil
        label.isHidden = false
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard sel == #selector(NSResponder.cancelOperation(_:)) else { return false }
        endRename()
        return true
    }

    func controlTextDidEndEditing(_ note: Notification) {
        // Enter has already sent the action (and the row is being rebuilt); anything else cancels.
        if (note.userInfo?["NSTextMovement"] as? Int) != NSTextMovement.return.rawValue { endRename() }
    }

    /// Middle-click closes the page, like its context menu's Close; ⇧⌘T brings it back.
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber != 2 { super.otherMouseDown(with: event) }
    }
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { sidebar.onClose(row.id) } else { super.otherMouseUp(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Rename…", action: #selector(renameFromMenu), keyEquivalent: "").target = self
        menu.addItem(withTitle: row.hasChildren ? "Close Page and Pages Beneath" : "Close Page", action: #selector(closeFromMenu), keyEquivalent: "").target = self
        return menu
    }
    @objc private func renameFromMenu() { beginRename() }
    @objc private func closeFromMenu() { sidebar.onClose(row.id) }

    // MARK: Drag and drop

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownAt, hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 4 else { return }
        mouseDownAt = nil
        let item = NSPasteboardItem()
        item.setString(String(row.id), forType: pageDragType)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let image = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            image.addRepresentation(rep)
        }
        dragging.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [dragging], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    private func place(for sender: NSDraggingInfo) -> DropPlace {
        let y = convert(sender.draggingLocation, from: nil).y / max(bounds.height, 1)
        return y > 0.72 ? .before : (y < 0.28 ? .after : .inside)
    }

    private func draggedPage(_ sender: NSDraggingInfo) -> UInt64? {
        sender.draggingPasteboard.string(forType: pageDragType).flatMap(UInt64.init)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let page = draggedPage(sender), page != row.id else {
            drop = nil
            return []
        }
        drop = place(for: sender)
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { drop = nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { drop = nil }
        guard let page = draggedPage(sender), page != row.id else { return false }
        sidebar.onPlace(page, row.id, place(for: sender))
        return true
    }
}

/// The draggable edge between the sidebar and the page.
@MainActor
final class DividerView: NSView {
    var onDrag: (CGFloat) -> Void = { _ in }
    /// Accessibility clients set the sidebar width in points, which is how runs resize it.
    var onSet: (CGFloat) -> Void = { _ in }
    /// The sidebar's current width, reported as the accessibility value.
    var width: CGFloat = 0

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .splitter }
    override func accessibilityIdentifier() -> String { "mako.divider" }
    override func accessibilityLabel() -> String? { "Sidebar width" }
    override func accessibilityValue() -> Any? { String(Int(width)) }
    override func setAccessibilityValue(_ value: Any?) {
        if let points = (value as? String).flatMap(Double.init) ?? (value as? NSNumber)?.doubleValue { onSet(points) }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height).fill()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func mouseDragged(with event: NSEvent) { onDrag(event.deltaX) }
    override var mouseDownCanMoveWindow: Bool { false }
}
