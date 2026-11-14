import AppKit

private let pageDragType = NSPasteboard.PasteboardType("com.wego.mako.page")

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }

    /// `light` in light mode, `dark` in dark mode.
    static func adaptive(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }

    static let sidebarPaper = adaptive(NSColor(hex: 0xf1e8d6), NSColor(hex: 0x23201c))
    static let ink = adaptive(NSColor(hex: 0x2a201a), NSColor(hex: 0xece3d3))
    static let cardShadow = adaptive(NSColor(hex: 0x3c1e0a, alpha: 0.22), NSColor(hex: 0x000000, alpha: 0.45))
    /// Terracotta: a warning that still sits on cream paper.
    static let caution = adaptive(NSColor(hex: 0xa8502e), NSColor(hex: 0xe58d6c))

    /// Earthy inks that read on cream paper, each lightened for dark mode: green, blue, pink,
    /// ochre, plum, teal, wine, forest, umber.
    private static let trailInks: [(light: UInt32, dark: UInt32)] = [
        (0x839d56, 0x97b561), (0x46648c, 0x92add2), (0xc7735f, 0xe29988), (0xd9902a, 0xebb060), (0x7a4fa0, 0xb690dc),
        (0x2f7f7a, 0x6cbfb8), (0x8c3a5a, 0xd59ab1), (0x2f6b3a, 0x6fae7c), (0x8a6a3a, 0xc4a274),
    ]

    /// A trail's colour by the core's slot.
    static func trail(_ slot: Int) -> NSColor {
        let ink = trailInks[slot % trailInks.count]
        return adaptive(NSColor(hex: ink.light), NSColor(hex: ink.dark))
    }

    /// A trail's card: paper with 18% of the trail's colour.
    static func card(_ slot: Int) -> NSColor {
        let ink = trailInks[slot % trailInks.count]
        return adaptive(NSColor(hex: 0xfbf7ee).blended(withFraction: 0.18, of: NSColor(hex: ink.light))!,
                     NSColor(hex: 0x2e2a25).blended(withFraction: 0.18, of: NSColor(hex: ink.dark))!)
    }
}

extension TrailRow {
    /// The core's flat rows split into trails: each depth-0 row starts one.
    static func trails(_ rows: [TrailRow]) -> [[TrailRow]] {
        rows.reduce(into: []) { trails, row in
            if row.depth == 0 || trails.isEmpty { trails.append([row]) } else { trails[trails.count - 1].append(row) }
        }
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
    var onOpenConfig: () -> Void = {}
    /// The pointer left the sidebar.
    var onExit: () -> Void = {}
    /// Peeking over the page: a shadow lifts it off the page beneath.
    var floats = false { didSet { layer?.shadowOpacity = floats ? 0.28 : 0 } }

    private let scroll = NSScrollView()
    private var rowsTop: NSLayoutConstraint!

    private let stack = NSStackView()
    /// Shown only while a config line is unusable; a click opens the config file.
    private let configNote = ConfigNote(labelWithString: "")
    /// Shown only at the trail cap: a quiet note, not an alarm.
    private let load = NSTextField(labelWithString: "")
    /// The notes at the sidebar's foot; hidden ones take no room.
    private let footer = NSStackView()
    private var rowsToBottom: NSLayoutConstraint!
    private var rowsToFooter: NSLayoutConstraint!
    private var rowViews: [UInt64: RowView] = [:]
    private var generation = 0

    init() {
        super.init(frame: .zero)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        // Room on every side for the cards' shadows, which the scroll view would clip.
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 18, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        load.font = .systemFont(ofSize: 12)
        load.textColor = .ink.withAlphaComponent(0.62)
        load.toolTip = "At your trail limit – finish or close a trail to start another"
        load.setAccessibilityIdentifier("mako.sidebar.load")
        load.isHidden = true
        configNote.font = .systemFont(ofSize: 12)
        configNote.textColor = .caution
        configNote.lineBreakMode = .byTruncatingTail
        configNote.maximumNumberOfLines = 2
        configNote.cell?.wraps = true
        configNote.cell?.truncatesLastVisibleLine = true
        configNote.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        configNote.setAccessibilityIdentifier("mako.sidebar.config")
        configNote.isHidden = true
        configNote.onClick = { [unowned self] in onOpenConfig() }
        footer.orientation = .vertical
        footer.alignment = .width
        footer.spacing = 4
        footer.setViews([configNote, load], in: .leading)
        footer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(footer)
        wantsLayer = true
        layer?.shadowRadius = 14
        layer?.shadowOffset = CGSize(width: 3, height: 0)
        rowsTop = scroll.topAnchor.constraint(equalTo: topAnchor)
        rowsToBottom = scroll.bottomAnchor.constraint(equalTo: bottomAnchor)
        rowsToFooter = scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -6)
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityIdentifier("mako.sidebar")
        setAccessibilityLabel("Trails")
        NSLayoutConstraint.activate([
            rowsTop,
            rowsToBottom,
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
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

    override func draw(_ dirtyRect: NSRect) {
        NSColor.sidebarPaper.setFill()
        // Views no longer clip to their bounds, so dirtyRect can reach over the page beside.
        dirtyRect.intersection(bounds).fill()
    }

    /// Starts the cards below `anchor`, which keeps the traffic lights clear.
    func pinRows(below anchor: NSLayoutYAxisAnchor) {
        rowsTop.isActive = false
        rowsTop = scroll.topAnchor.constraint(equalTo: anchor)
        rowsTop.isActive = true
    }

    // MARK: Moving the window

    /// The paper between and around the cards moves the window, as a title bar would.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit === self || hit === scroll || hit === scroll.contentView || hit === scroll.documentView || hit === stack ? self : hit
    }
    override func mouseDown(with event: NSEvent) { window?.moveOrZoom(event) }
    override func scrollWheel(with event: NSEvent) { scroll.scrollWheel(with: event) }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    override func mouseExited(with event: NSEvent) {
        // A rename in progress keeps the sidebar out.
        if (window?.firstResponder as? NSView)?.isDescendant(of: self) != true { onExit() }
    }

    func update(_ rows: [TrailRow]) {
        generation += 1
        let mine = generation
        // Removing a row that is being renamed ends its editing, which can save the name and
        // redraw from inside this loop. That newer redraw wins; this one stops.
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard mine == generation else { return }
        rowViews = [:]
        for trail in TrailRow.trails(rows) {
            let views = trail.map { row in
                let view = RowView(row, sidebar: self)
                rowViews[row.id] = view
                view.setIcon(iconFor(row))
                return view
            }
            let card = CardView(views, color: trail[0].color)
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
    }

    func beginRename(_ id: UInt64) { rowViews[id]?.beginRename() }

    /// Open trails against the cap; the note shows once no new trail fits.
    func showLoad(trails: Int, max: Int) {
        load.stringValue = "🧠 \(trails)/\(max)"
        load.isHidden = trails < max
        fitFooter()
    }

    /// The core's note on unusable config lines, or nil to hide it.
    func showConfigIssue(_ issue: String?) {
        configNote.stringValue = issue.map { "⚠ \($0)" } ?? ""
        configNote.toolTip = issue.map { "\($0)\nClick to open the config file." }
        configNote.isHidden = issue == nil
        fitFooter()
    }

    private func fitFooter() {
        let shown = footer.arrangedSubviews.contains { !$0.isHidden }
        guard rowsToFooter.isActive != shown else { return }
        rowsToBottom.isActive = !shown
        rowsToFooter.isActive = shown
    }

    /// Icons arrive after the rows are drawn; updating in place keeps a rename in progress.
    func refreshIcons() { rowViews.values.forEach { $0.setIcon(iconFor($0.row)) } }
}

/// One trail: a raised paper card in the trail's colour, its pages joined by ink branches.
@MainActor
private final class CardView: NSView {
    private let rows: [RowView]
    private let color: Int

    init(_ rows: [RowView], color: Int) {
        self.rows = rows
        self.color = color
        super.init(frame: .zero)
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 5, bottom: 5, right: 5)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ] + rows.map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -10) })
        wantsLayer = true
        layer?.shadowOpacity = 1
        layer?.shadowOffset = CGSize(width: 0, height: -3.5)
        layer?.shadowRadius = 4.25
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        guard let layer else { return }
        layer.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 6, cornerHeight: 6, transform: nil)
        effectiveAppearance.performAsCurrentDrawingAppearance { layer.shadowColor = NSColor.cardShadow.cgColor }
        // The dots and branches are drawn at the rows' frames, which layout just moved.
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() { needsLayout = true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.card(color).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        let ink = NSColor.trail(color)
        for row in rows {
            let frame = convert(row.bounds, from: row)
            if row.row.depth == 0 {
                let center = NSPoint(x: frame.minX + 13, y: frame.midY)
                ink.withAlphaComponent(0.22).setFill()
                NSBezierPath(ovalIn: NSRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16)).fill()
                ink.setFill()
                NSBezierPath(ovalIn: NSRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)).fill()
            } else {
                // Starts 6 pt up inside the page above, so the branch reads as growing out of it.
                let x = frame.minX + 14.75 + CGFloat(row.level - 1) * 16, y = frame.midY + 0.75
                let branch = NSBezierPath()
                branch.move(to: NSPoint(x: x, y: frame.maxY + 6))
                branch.appendArc(from: NSPoint(x: x, y: y), to: NSPoint(x: x + 8.25, y: y), radius: 7.25)
                branch.line(to: NSPoint(x: x + 8.25, y: y))
                branch.lineWidth = 1.5
                ink.withAlphaComponent(0.85).setStroke()
                branch.stroke()
            }
        }
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A label that acts on a click or an accessibility press.
private final class ConfigNote: NSTextField {
    var onClick: () -> Void = {}
    override func mouseDown(with event: NSEvent) { onClick() }
    override func accessibilityPerformPress() -> Bool {
        onClick()
        return true
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// One page in the sidebar: click to show it, double-click to rename, drag to move it
/// (with the pages beneath it) before, after, or inside another page.
@MainActor
private final class RowView: NSView, NSDraggingSource, NSTextFieldDelegate {
    let row: TrailRow
    private let icon = NSImageView()
    private unowned let sidebar: Sidebar
    private let label: NSTextField
    private var hovered = false { didSet { needsDisplay = true } }
    private var drop: DropPlace? { didSet { needsDisplay = true } }
    private var mouseDownAt: NSPoint?
    private var editor: NSTextField?
    private var indent: NSLayoutConstraint!

    /// Levels the row is drawn in: its depth, capped so the name keeps 40 pt beside the toggle.
    /// Past the first level each adds 16 pt; the icon, gaps and toggle take 70.
    var level: Int { min(row.depth, max(1, Int((bounds.width - 70 - 40) / 16) + 1)) }

    init(_ row: TrailRow, sidebar: Sidebar) {
        self.row = row
        self.sidebar = sidebar
        label = NSTextField(labelWithString: row.label)
        super.init(frame: .zero)

        let toggle = NSButton(title: row.hasChildren ? (row.collapsed ? "▸" : "▾") : "", target: self, action: #selector(toggled))
        toggle.isBordered = false
        toggle.attributedTitle = NSAttributedString(string: toggle.title, attributes: [
            .foregroundColor: NSColor.ink.withAlphaComponent(0.55), .font: NSFont.systemFont(ofSize: 11),
        ])
        // Kept in the row (not hidden) so every name ends at the same place.
        toggle.isEnabled = row.hasChildren
        toggle.setAccessibilityElement(row.hasChildren)
        toggle.setAccessibilityIdentifier("mako.trail.\(row.id).toggle")
        toggle.setAccessibilityLabel(row.collapsed ? "Expand" : "Collapse")

        label.font = .systemFont(ofSize: 13, weight: row.active ? .semibold : (row.depth == 0 ? .medium : .regular))
        label.textColor = .ink
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
        // The card draws the root's dot and the branches in the space before the icon.
        indent = icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 26)
        // Below required: when the sidebar narrows, layout solves the new width with the old
        // indent once before layout() caps it, and the name must not break a constraint then.
        indent.priority = .init(999)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            indent,
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: toggle.leadingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            toggle.widthAnchor.constraint(equalToConstant: 14),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
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

    override func layout() {
        indent.constant = 26 + CGFloat(max(level - 1, 0)) * 16
        super.layout()
    }

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
        let shape = NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4)
        if row.active {
            NSColor.trail(row.color).withAlphaComponent(0.18).setFill()
            shape.fill()
        } else if hovered || drop == .inside {
            NSColor.ink.withAlphaComponent(drop == .inside ? 0.14 : 0.06).setFill()
            shape.fill()
        }
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
