import AppKit

/// Settings window (⌘.): the trail cap. Everything else lives in the config file, one button away.
@MainActor
final class Settings: NSObject {
    private lazy var window: NSWindow = {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 150), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Settings"
        w.isReleasedWhenClosed = false
        let label = NSTextField(labelWithString: "Maximum trails:")
        let note = NSTextField(wrappingLabelWithString: "Pages within a trail are unlimited. Lowering the cap keeps open trails; it stops new ones.")
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let config = NSButton(title: "Open Config File…", target: (NSApp.delegate as? AppDelegate)?.browser, action: #selector(Browser.openConfig))
        field.setAccessibilityIdentifier("mako.settings.maxTrails")
        field.target = self
        field.action = #selector(fieldChanged)
        field.widthAnchor.constraint(equalToConstant: 44).isActive = true
        stepper.minValue = 1
        stepper.maxValue = 9
        stepper.valueWraps = false
        stepper.target = self
        stepper.action = #selector(stepped)
        stepper.setAccessibilityIdentifier("mako.settings.maxTrails.stepper")
        let row = NSStackView(views: [label, field, stepper])
        let stack = NSStackView(views: [row, note, config])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        w.contentView = stack
        return w
    }()
    private let field = NSTextField()
    private let stepper = NSStepper()

    @objc func show(_: Any?) {
        display(Core.maxTrails)
        window.center()
        if Browser.background { window.orderFront(nil) } else { window.makeKeyAndOrderFront(nil) }
    }

    private func display(_ n: Int) {
        field.stringValue = String(n)
        stepper.integerValue = n
    }

    @objc private func stepped(_: Any?) { save(stepper.integerValue) }

    /// Anything but a whole number in the stepper's range is refused and the saved value shown again.
    @objc private func fieldChanged(_: Any?) {
        guard let n = Int(field.stringValue.trimmingCharacters(in: .whitespaces)), (1...9).contains(n) else { return display(Core.maxTrails) }
        save(n)
    }

    private func save(_ n: Int) {
        Core.set("max_trails", String(n))
        display(Core.maxTrails)
    }
}
