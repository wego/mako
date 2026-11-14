import AppKit

/// The rows under the omnibox field: open pages and history that match what is typed.
/// ↑ and ↓ select a row for Return; the pointer only tints the row under it, so a pointer
/// resting where the list appears never changes what Return does.
@MainActor
final class SuggestionList: NSView {
    /// A row was clicked or pressed through accessibility; true when Option was held.
    var onPick: (Int, Bool) -> Void = { _, _ in }
    /// The trail colour slot of the open omnibox, for the selected row's tint.
    var slot: Int? { didSet { rows.forEach { $0.slot = slot } } }
    private(set) var selected: Int? { didSet { rows.enumerated().forEach { $1.isSelected = $0 == selected } } }
    private var rows: [SuggestionRow] = []
    private let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 9, left: 0, bottom: 0, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows `suggestions` with none selected; `icon` is each row's site icon, if one is held.
    func show(_ suggestions: [Suggestion], icon: (Suggestion) -> NSImage?) {
        rows.forEach { $0.removeFromSuperview() }
        rows = suggestions.enumerated().map { index, suggestion in
            let row = SuggestionRow(suggestion, index: index, icon: icon(suggestion))
            row.slot = slot
            row.onPick = { [unowned self] in onPick(index, $0) }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            return row
        }
        selected = nil
        isHidden = rows.isEmpty
        needsDisplay = true
    }

    /// ↓ and ↑: from no row to the first or last, through the rows, and back to none.
    func move(by step: Int) {
        guard !rows.isEmpty else { return }
        let next = (selected ?? (step > 0 ? -1 : rows.count)) + step
        selected = rows.indices.contains(next) ? next : nil
    }

    /// A hairline between the field and the rows.
    override func draw(_ dirtyRect: NSRect) {
        NSColor.ink.withAlphaComponent(0.12).setFill()
        NSRect(x: 8, y: bounds.maxY - 1, width: bounds.width - 16, height: 1).fill()
    }
}

/// One suggestion: the site's icon or a globe, the title, the address in a quieter ink, and
/// for a page that is already open its trail's dot and "Open".
@MainActor
private final class SuggestionRow: NSView {
    var onPick: (Bool) -> Void = { _ in }
    var slot: Int? { didSet { needsDisplay = true } }
    var isSelected = false {
        didSet {
            needsDisplay = true
            setAccessibilityValue(isSelected ? "selected" : "")
        }
    }
    private var hovered = false { didSet { needsDisplay = true } }

    init(_ suggestion: Suggestion, index: Int, icon image: NSImage?) {
        super.init(frame: .zero)
        let icon = NSImageView()
        icon.image = image ?? .globe
        icon.contentTintColor = image == nil ? .ink.withAlphaComponent(0.45) : nil
        icon.imageScaling = .scaleProportionallyUpOrDown
        let title = NSTextField(labelWithString: suggestion.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.textColor = .ink
        let address = NSTextField(labelWithString: Self.shown(suggestion.url))
        address.font = .systemFont(ofSize: 12)
        address.textColor = .ink.withAlphaComponent(0.55)
        for label in [title, address] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        // The title takes what it needs, up to three fifths of the row; the address gets the rest.
        title.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        address.setContentHuggingPriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [icon, title, address]
        if let open = suggestion.open { views.append(OpenBadge(slot: open.color)) }
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.setAccessibilityElement(false)
            addSubview(view)
        }
        let last = views.last!
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            title.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.6),
            address.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 10),
            last.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ] + views.map { $0.centerYAnchor.constraint(equalTo: centerYAnchor) })
        if last !== address { address.trailingAnchor.constraint(equalTo: last.leadingAnchor, constant: -12).isActive = true }
        toolTip = suggestion.url
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("mako.omnibox.suggestion.\(index)")
        setAccessibilityTitle(suggestion.title)
        setAccessibilityLabel("\(suggestion.open == nil ? "History" : "Open page") – \(suggestion.url)")
        setAccessibilityValue("")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The address as a person reads it: no scheme, no `www.`, no lone trailing slash.
    private static func shown(_ url: String) -> String {
        var text = url.split(separator: "://", maxSplits: 1).last.map(String.init) ?? url
        if text.hasPrefix("www.") { text.removeFirst(4) }
        if text.hasSuffix("/"), text.firstIndex(of: "/") == text.index(before: text.endIndex) { text.removeLast() }
        return text
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected || hovered else { return }
        let tint = isSelected ? (slot.map(NSColor.trail) ?? .ink).withAlphaComponent(0.24) : NSColor.ink.withAlphaComponent(0.06)
        tint.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPick(event.modifierFlags.contains(.option)) }
    }

    override func accessibilityPerformPress() -> Bool {
        onPick(false)
        return true
    }
}

/// Marks a suggestion as a page that is already open: its trail's dot and "Open".
@MainActor
private final class OpenBadge: NSView {
    private let slot: Int
    private static let text = NSAttributedString(string: "Open", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)])

    init(slot: Int) {
        self.slot = slot
        super.init(frame: .zero)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: 8 + 6 + ceil(Self.text.size().width), height: 16) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.trail(slot).setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: bounds.midY - 4, width: 8, height: 8)).fill()
        let text = NSMutableAttributedString(attributedString: Self.text)
        text.addAttribute(.foregroundColor, value: NSColor.ink.withAlphaComponent(0.7), range: NSRange(location: 0, length: text.length))
        text.draw(at: NSPoint(x: 14, y: bounds.midY - text.size().height / 2))
    }
}
