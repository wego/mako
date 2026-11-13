import AppKit
import WebKit
import os

let log = Logger(subsystem: "com.wego.mako", category: "browser")

/// MAKO_PERF=1 (set by verification runs, never in daily use) logs how long an action
/// keeps the main thread busy, from the input event until the run loop next idles.
/// Logs action names only, never key characters.
@MainActor enum Perf {
    static let enabled = ProcessInfo.processInfo.environment["MAKO_PERF"] == "1"
    private static var firstPageLogged = false

    static func measure(_ action: StaticString) {
        guard enabled, let start = NSApp.currentEvent?.timestamp else { return }
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, 0) { o, _ in
            log.info("perf \(action, privacy: .public) \(Int((ProcessInfo.processInfo.systemUptime - start) * 1_000_000))us")
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), o, .commonModes)
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    /// Process start to the first page finishing its load. Includes WebKit's own process
    /// start-up, which varies by ~100ms run to run.
    static func firstPage() {
        guard enabled, !firstPageLogged else { return }
        firstPageLogged = true
        log.info("perf launchToFirstPage \(sinceProcessStart())us")
    }

    /// Process start until the main thread first idles after launching: the part of launch
    /// Mako controls, and when the window starts taking input.
    static func interactiveAfterLaunch() {
        guard enabled else { return }
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, 0) { o, _ in
            log.info("perf launchToInteractive \(sinceProcessStart())us")
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), o, .commonModes)
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    private static func sinceProcessStart() -> Int {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return 0 }
        let started = info.kp_proc.p_un.__p_starttime
        return Int((Date().timeIntervalSince1970 - (Double(started.tv_sec) + Double(started.tv_usec) / 1e6)) * 1_000_000)
    }
}

/// Offers only Mako-owned shortcuts to the main menu first so pages cannot hijack trail
/// and omnibox controls. Editing and navigation shortcuts keep AppKit's order.
final class MenuFirstWindow: NSWindow {
    private static let owned: [(NSEvent.ModifierFlags, String)] = [
        (.command, "t"), ([.command, .option], "t"), ([.command, .shift], "t"),
        (.command, "w"), (.command, "l"), (.command, ","), (.command, "."), ([.command, .option], "c"),
    ] + (1...9).map { (.command, String($0)) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .shift, .control])
        // ⌃Tab / ⌃⇧Tab: menus match Tab unreliably, so route it here.
        if event.keyCode == 48, mods.subtracting(.shift) == .control {
            let action = mods.contains(.shift) ? #selector(Browser.previousPage) : #selector(Browser.nextPage)
            return NSApp.sendAction(action, to: delegate, from: self)
        }
        if let key = event.charactersIgnoringModifiers?.lowercased(),
           Self.owned.contains(where: { $0.0 == mods && $0.1 == key }),
           NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// One window: a sidebar of trails beside the active page. A followed link opens beneath
/// the page it came from. The core owns the tree; this owns the web views and the window.
@MainActor
final class Browser: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, NSTextFieldDelegate {
    /// Set by verification runs so a test copy never takes focus from the person using the Mac.
    static let background = ProcessInfo.processInfo.environment["MAKO_BACKGROUND"] == "1"
    /// Pages kept loaded; the rest reload from their saved address when selected.
    static let maxLiveViews = 8

    private enum OmniTarget { case current, newTrail, child(UInt64), find }

    let window: NSWindow
    private let store = TrailStore()
    /// Loaded pages by page id. Most pages have no web view until selected.
    private var views: [UInt64: WKWebView] = [:]
    private var observations: [UInt64: [NSKeyValueObservation]] = [:]
    /// Page ids, least recently shown first.
    private var recency: [UInt64] = []
    /// Last address and title reported to the core per page, to skip no-op updates.
    private var reported: [UInt64: [String]] = [:]
    private var shown: WKWebView?
    private var omniTarget = OmniTarget.current
    /// Script-opened windows (OAuth sign-in) live outside the trails.
    private var popups: [NSWindow] = []
    private var popupObservations: [NSKeyValueObservation] = []
    private let webConfig = WKWebViewConfiguration()
    private let container = NSView()
    private let sidebar = Sidebar()
    private let favicons = Favicons()
    private let divider = DividerView()
    private var sidebarWidth: NSLayoutConstraint!
    private let blank = NSImageView()
    /// Kept in sync on every change so the AX tree never depends on the menu being opened.
    let trailsMenu = NSMenu(title: "Trails")
    private let omnibox = NSGlassEffectView()
    private let field = OmniboxField()
    private let hint = NSTextField(labelWithString: "")

    override init() {
        window = MenuFirstWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        super.init()
        window.delegate = self
        window.tabbingMode = .disallowed
        buildLayout()
        divider.width = sidebarWidth.constant
        // After the layout exists: installing a constraint-based content view resizes the window.
        window.setContentSize(NSSize(width: 1200, height: 800))
        window.setFrameAutosaveName("main")
        webConfig.preferences.isElementFullscreenEnabled = true
        webConfig.preferences.setValue(true, forKey: "developerExtrasEnabled")
        // Google and others refuse sign-in from web views whose user agent lacks Safari's token.
        let safari = Bundle(path: "/Applications/Safari.app")?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "26.0"
        webConfig.applicationNameForUserAgent = "Version/\(safari) Safari/605.1.15"
        buildOmnibox()
        render()
        if Self.background { window.orderBack(nil) } else { window.makeKeyAndOrderFront(nil) }
        if store.active == nil { showOmnibox(for: .newTrail) }
    }

    private func buildLayout() {
        container.setAccessibilityElement(true)
        container.setAccessibilityRole(.group)
        container.setAccessibilityIdentifier("mako.page")
        container.setAccessibilityLabel("Page")
        blank.setAccessibilityIdentifier("mako.blank")
        blank.setAccessibilityLabel("No page")
        blank.image = NSApp.applicationIconImage
        blank.imageScaling = .scaleProportionallyUpOrDown
        blank.alphaValue = 0.9
        blank.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(blank)

        sidebar.onSelect = { [unowned self] in select($0) }
        sidebar.onToggle = { [unowned self] in toggle($0) }
        sidebar.onRename = { [unowned self] in apply("rename", ["id": $0, "name": $1]) }
        sidebar.onClose = { [unowned self] in close($0) }
        sidebar.onPlace = { [unowned self] in apply("place", ["id": $0, "target": $1, "place": $2.rawValue]) }
        sidebar.iconFor = { [unowned self] in favicons.icon(for: $0.url) }
        favicons.onChange = { [unowned self] in sidebar.refreshIcons() }
        divider.onDrag = { [unowned self] in setSidebarWidth(sidebarWidth.constant + $0) }
        divider.onSet = { [unowned self] in setSidebarWidth($0) }

        let root = NSView()
        for view in [sidebar, divider, container] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
            view.topAnchor.constraint(equalTo: root.topAnchor).isActive = true
            view.bottomAnchor.constraint(equalTo: root.bottomAnchor).isActive = true
        }
        window.contentView = root
        // A fifth of the window to start with; a dragged width is remembered.
        let saved = UserDefaults.standard.double(forKey: "sidebarWidth")
        sidebarWidth = sidebar.widthAnchor.constraint(equalToConstant: saved > 0 ? saved : min(max(window.frame.width * 0.2, 200), 320))
        NSLayoutConstraint.activate([
            blank.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            blank.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            blank.widthAnchor.constraint(equalToConstant: 128),
            blank.heightAnchor.constraint(equalToConstant: 128),
            sidebarWidth,
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            // The divider is wider than the line it draws so it is easy to grab.
            divider.centerXAnchor.constraint(equalTo: sidebar.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 7),
            container.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 400),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ])
        root.addSubview(divider, positioned: .above, relativeTo: nil)
    }

    private func setSidebarWidth(_ width: CGFloat) {
        sidebarWidth.constant = min(max(width, 160), max(160, min(480, window.frame.width - 400)))
        divider.width = sidebarWidth.constant
        UserDefaults.standard.set(Double(sidebarWidth.constant), forKey: "sidebarWidth")
    }

    private func page(_ webView: WKWebView) -> URL? {
        guard let url = webView.url, ["http", "https", "data", "file"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    private func id(of webView: WKWebView) -> UInt64? { views.first { $0.value === webView }?.key }

    // MARK: Trails

    /// Asks the core for a change and redraws. Returns the core's error message, if any.
    @discardableResult
    private func apply(_ type: String, _ fields: [String: Any] = [:]) -> String? {
        let error = store.apply(type, fields)
        if let error { log.info("trails \(type, privacy: .public) refused: \(error, privacy: .public)") }
        render()
        return error
    }

    /// Makes the window match the store: loaded pages, the visible page, sidebar, menu, title.
    private func render() {
        for id in views.keys where !store.pages.contains(id) { unload(id) }
        let active = store.active
        let view = active.map(liveView)
        if view !== shown {
            shown?.removeFromSuperview()
            shown = view
            if let view {
                view.frame = container.bounds
                view.autoresizingMask = [.width, .height]
                container.addSubview(view, positioned: .below, relativeTo: omnibox)
            }
        }
        if let id = active?.id {
            recency.removeAll { $0 == id }
            recency.append(id)
        }
        for id in recency.dropLast(Self.maxLiveViews) { unload(id) }
        blank.isHidden = active != nil
        window.title = active?.label ?? "Mako"
        window.subtitle = ""
        if !omnibox.isHidden { updateHint() }
        sidebar.update(store.rows)
        rebuildTrailsMenu()
        if omnibox.isHidden, let view { window.makeFirstResponder(view) }
    }

    /// The page's web view, created and loaded from its saved address on first use.
    private func liveView(_ row: TrailRow) -> WKWebView {
        if let view = views[row.id] { return view }
        let id = row.id
        let w = PageView(frame: .zero, configuration: webConfig)
        w.onBackgroundLink = { [weak self] url in self?.apply("open_child", ["parent": id, "url": url.absoluteString, "select": false]) }
        w.navigationDelegate = self
        w.uiDelegate = self
        w.allowsBackForwardNavigationGestures = true
        w.allowsMagnification = true
        w.isInspectable = true
        w.setAccessibilityIdentifier("mako.trail.\(id).page")
        observations[id] = [
            w.observe(\.title) { [weak self] _, _ in MainActor.assumeIsolated { self?.pageChanged(id) } },
            w.observe(\.url) { [weak self] _, _ in MainActor.assumeIsolated { self?.pageChanged(id) } },
        ]
        views[id] = w
        reported[id] = [row.url, row.title]
        if let url = URL(string: row.url) { w.load(URLRequest(url: url)) }
        return w
    }

    private func unload(_ id: UInt64) {
        guard let view = views.removeValue(forKey: id) else { return }
        observations[id] = nil
        reported[id] = nil
        recency.removeAll { $0 == id }
        if view === shown { shown = nil }
        view.removeFromSuperview()
    }

    /// A page changed address or title in place (redirect, form, in-page navigation).
    private func pageChanged(_ id: UInt64) {
        guard let view = views[id], let url = page(view)?.absoluteString else { return }
        let now = [url, view.title ?? ""]
        guard reported[id] != now else { return }
        reported[id] = now
        apply("navigated", ["id": id, "url": now[0], "title": now[1]])
    }

    private func rebuildTrailsMenu() {
        trailsMenu.removeAllItems()
        for (title, action) in [("Next Page", #selector(nextPage(_:))), ("Previous Page", #selector(previousPage(_:)))] {
            trailsMenu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        trailsMenu.addItem(.separator())
        for (title, action) in [("Move Page Up", #selector(movePageUp(_:))), ("Move Page Down", #selector(movePageDown(_:))),
                                ("Indent Page", #selector(indentPage(_:))), ("Outdent Page", #selector(outdentPage(_:))),
                                ("Rename Page…", #selector(renamePage(_:)))] {
            trailsMenu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        trailsMenu.addItem(.separator())
        var trail = 0
        for row in store.rows {
            let item = NSMenuItem(title: row.label, action: #selector(selectMenuRow(_:)), keyEquivalent: "")
            item.indentationLevel = row.depth
            item.target = self
            item.tag = Int(row.id)
            item.state = row.active ? .on : .off
            // A trail's root carries its ⌘1…⌘9 jump, so each trail is listed once.
            if row.depth == 0 {
                trail += 1
                item.image = Self.dot(.trail(row.color))
                item.action = #selector(jumpToTrail(_:))
                item.tag = trail - 1
                if trail <= 9 { item.keyEquivalent = String(trail) }
            }
            trailsMenu.addItem(item)
        }
    }

    private static func dot(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    /// Opens an external link: a new trail while there is room, else a page in the current trail.
    func open(_ url: URL) {
        hideOmnibox()
        if apply("open_trail", ["url": url.absoluteString]) != nil, let parent = store.active?.id {
            apply("open_child", ["parent": parent, "url": url.absoluteString])
        }
    }

    // MARK: Omnibox

    private func buildOmnibox() {
        omnibox.setAccessibilityElement(true)
        omnibox.setAccessibilityRole(.group)
        omnibox.setAccessibilityIdentifier("mako.omnibox")
        omnibox.setAccessibilityLabel("Address bar")
        field.setAccessibilityIdentifier("mako.omnibox.field")
        field.setAccessibilityLabel("Address or search")
        hint.setAccessibilityIdentifier("mako.omnibox.status")
        hint.setAccessibilityLabel("Status")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = OmniboxField.font(18)
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: field, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.field.fitFont() }
        }
        field.placeholderString = "Search or enter address"
        field.delegate = self
        // Enter arrives as the field's action, which accessibility clients can trigger too.
        field.target = self
        field.action = #selector(omniboxEntered(_:))
        hint.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        hint.maximumNumberOfLines = 0

        let stack = NSStackView(views: [field, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 18, bottom: 14, right: 18)
        omnibox.contentView = stack
        omnibox.cornerRadius = 18
        omnibox.isHidden = true
        omnibox.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(omnibox)
        NSLayoutConstraint.activate([
            omnibox.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            omnibox.topAnchor.constraint(equalTo: container.topAnchor, constant: 80),
            omnibox.widthAnchor.constraint(equalTo: container.widthAnchor, multiplier: 0.7),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            // The 18 pt line height at every font size, so the panel never jumps while typing.
            field.heightAnchor.constraint(equalToConstant: OmniboxField.height),
        ])
    }

    private func showOmnibox(for target: OmniTarget, text: String? = nil, message: String? = nil) {
        omniTarget = target
        field.stringValue = text ?? ""
        updateHint(message: message)
        omnibox.isHidden = false
        container.addSubview(omnibox, positioned: .above, relativeTo: nil)
        window.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        container.layoutSubtreeIfNeeded()
        field.fitFont()
    }

    func controlTextDidChange(_ note: Notification) {
        if note.object as? NSTextField === field { field.fitFont() }
    }

    private func updateHint(message: String? = nil) {
        let purpose = switch omniTarget {
        case .current: store.active == nil ? "Starts a new trail" : "Loads in this page"
        case .newTrail: "Starts a new trail"
        case .child: "Opens a page beneath this one"
        case .find: "Finds in this page – Enter for the next match"
        }
        let trails = store.rows.filter { $0.depth == 0 }.count
        hint.stringValue = [message ?? Core.configError, purpose, "\(trails) trail\(trails == 1 ? "" : "s"), \(store.pages.count) page\(store.pages.count == 1 ? "" : "s")"]
            .compactMap { $0 }.joined(separator: "\n")
    }

    private func hideOmnibox() {
        omnibox.isHidden = true
        if let shown { window.makeFirstResponder(shown) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard sel == #selector(NSResponder.cancelOperation(_:)) else { return false }
        hideOmnibox()
        return true
    }

    @objc func omniboxEntered(_: Any?) {
        guard !omnibox.isHidden else { return }
        if case .find = omniTarget { return findNext(nil) }
        guard let url = Core.resolve(field.stringValue) else { return hideOmnibox() }
        var error: String?
        switch omniTarget {
        case .current:
            if let shown { shown.load(URLRequest(url: url)) } else { error = store.apply("open_trail", ["url": url.absoluteString]) }
        case .newTrail:
            error = store.apply("open_trail", ["url": url.absoluteString])
        case .child(let parent):
            error = store.apply("open_child", ["parent": parent, "url": url.absoluteString])
        case .find: break
        }
        if let error {
            NSSound.beep()
            return updateHint(message: "Can’t open: \(error). ⌥⌘T opens a page in the current trail.")
        }
        omnibox.isHidden = true
        render()
    }

    // MARK: Menu actions

    @objc func newTrail(_: Any?) {
        Perf.measure("newTrail")
        showOmnibox(for: .newTrail)
    }
    @objc func newPage(_: Any?) {
        guard let parent = store.active?.id else { return showOmnibox(for: .newTrail) }
        showOmnibox(for: .child(parent))
    }
    @objc func openLocation(_: Any?) { showOmnibox(for: .current, text: shown.flatMap(page)?.absoluteString) }
    @objc func back(_: Any?) { shown?.goBack() }
    @objc func forward(_: Any?) { shown?.goForward() }
    @objc func reload(_: Any?) { shown?.reload() }
    @objc func zoomIn(_: Any?) { shown?.pageZoom += 0.1 }
    @objc func zoomOut(_: Any?) { if let shown { shown.pageZoom = max(0.3, shown.pageZoom - 0.1) } }
    @objc func zoomReset(_: Any?) { shown?.pageZoom = 1 }
    @objc func openConfig(_: Any?) { NSWorkspace.shared.open(Core.configURL) }

    @objc func findInPage(_: Any?) { showOmnibox(for: .find, text: field.stringValue) }
    @objc func findNext(_: Any?) { find(backwards: false) }
    @objc func findPrevious(_: Any?) { find(backwards: true) }
    private func find(backwards: Bool) {
        guard let shown, !field.stringValue.isEmpty else { return }
        let config = WKFindConfiguration()
        config.backwards = backwards
        shown.find(field.stringValue, configuration: config) { [weak self] result in
            if !result.matchFound { self?.updateHint(message: "Not found") }
        }
    }

    @objc func movePageUp(_: Any?) { nudge("up") }
    @objc func movePageDown(_: Any?) { nudge("down") }
    @objc func indentPage(_: Any?) { nudge("in") }
    @objc func outdentPage(_: Any?) { nudge("out") }
    private func nudge(_ direction: String) {
        guard let id = store.active?.id else { return }
        if apply("nudge", ["id": id, "direction": direction]) != nil { NSSound.beep() }
    }
    @objc func renamePage(_: Any?) { if let id = store.active?.id { sidebar.beginRename(id) } }

    @objc func selectMenuRow(_ sender: NSMenuItem) { select(UInt64(sender.tag)) }
    /// A trail's root, or from the root the trail's last page; the rule is the core's.
    @objc func jumpToTrail(_ sender: NSMenuItem) {
        Perf.measure("jumpToTrail")
        if apply("jump", ["trail": sender.tag]) != nil { NSSound.beep() }
    }
    private func select(_ id: UInt64) {
        Perf.measure("selectPage")
        apply("select", ["id": id])
    }

    private func toggle(_ id: UInt64) {
        guard let row = store.rows.first(where: { $0.id == id }) else { return }
        apply("set_collapsed", ["id": id, "collapsed": !row.collapsed])
    }

    @objc func nextPage(_: Any?) { step(1) }
    @objc func previousPage(_: Any?) { step(-1) }
    private func step(_ by: Int) {
        let rows = store.rows
        guard let i = rows.firstIndex(where: \.active) else { return }
        select(rows[(i + by + rows.count) % rows.count].id)
    }

    /// Closes the active page and the pages beneath it; Reopen Closed Page brings them back.
    @objc func closePage(_: Any?) {
        // ⌘W in the About panel or a sign-in popup closes that window, not a page behind it.
        if let key = NSApp.keyWindow, key !== window { return key.performClose(nil) }
        Perf.measure("closePage")
        guard let id = store.active?.id else { return NSSound.beep() }
        close(id)
    }

    private func close(_ id: UInt64) {
        apply("close", ["id": id])
        if store.active == nil { showOmnibox(for: .newTrail) }
    }

    @objc func reopenClosedPage(_: Any?) {
        if apply("undo_close") != nil { NSSound.beep() } else { hideOmnibox() }
    }

    /// WebKit has no public API to open the Web Inspector; this is the private
    /// _WKInspector that Safari's ⌥⌘C uses. Fine outside the App Store.
    @objc func toggleConsole(_: Any?) {
        guard let inspector = shown?.value(forKey: "_inspector") as? NSObject else { return NSSound.beep() }
        if inspector.value(forKey: "isVisible") as? Bool == true {
            inspector.perform(NSSelectorFromString("close"))
        } else {
            inspector.perform(NSSelectorFromString("showConsole"))
        }
    }

    // MARK: Navigation policy

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        let url = action.request.url
        let mainFrame = action.targetFrame?.isMainFrame ?? true
        // A download link obeys the blocklist like any other navigation, and like an
        // unshowable response it may only come from the page itself, not an embedded frame.
        if action.shouldPerformDownload {
            return mainFrame && action.sourceFrame.isMainFrame && url?.host().flatMap { Core.blockReason(host: $0) } == nil ? .download : .cancel
        }
        // A followed link opens beneath its page instead of replacing it. Jumps within the
        // same document (#section) and links in sign-in popups stay where they are. This comes
        // before the block check so a blocked link shows its notice in the new page, not over
        // the page it was clicked on.
        // So does whatever a middle-click starts (a script's `location = …` or window.open).
        if mainFrame, let url, isWeb(url), let parent = id(of: webView), !sameDocument(url, webView.url) {
            let background = [.linkActivated, .other].contains(action.navigationType) && (webView as? PageView)?.claimBackground() == true
            if background || action.navigationType == .linkActivated {
                log.info("child of \(parent) \(url.absoluteString, privacy: .public)\(background ? " (middle-click)" : "", privacy: .public)")
                // ⌘-click opens the page beneath this one without leaving it.
                apply("open_child", ["parent": parent, "url": url.absoluteString, "select": !(background || action.modifierFlags.contains(.command))])
                return .cancel
            }
        }
        if let host = url?.host(), let reason = Core.blockReason(host: host) {
            guard mainFrame else {
                // An embed (iframe) is just left empty; the page around it stays.
                log.info("block \(host, privacy: .public) (frame): \(reason, privacy: .public)")
                return .cancel
            }
            log.info("block \(host, privacy: .public): \(reason, privacy: .public)")
            webView.loadHTMLString(Self.blockPage(reason), baseURL: nil)
            return .cancel
        }
        log.info("allow \(url?.absoluteString ?? "", privacy: .public)")
        return .allow
    }

    // MARK: Downloads

    /// Anything WebKit cannot show (zip, dmg, ...) is saved to Downloads instead.
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if response.canShowMIMEType { return .allow }
        // Only the page itself may start a save, never an embedded frame, and never a blocked host.
        guard response.isForMainFrame, response.response.url?.host().flatMap({ Core.blockReason(host: $0) }) == nil else { return .cancel }
        return .download
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }

    /// Where each running download is going, and where it came from.
    private var downloads: [ObjectIdentifier: (file: URL, source: URL?)] = [:]

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        // The page chooses the name: keep only its last path component so it cannot leave Downloads.
        let name = URL(fileURLWithPath: suggestedFilename).lastPathComponent
        var target = folder.appending(path: name)
        var n = 1
        while FileManager.default.fileExists(atPath: target.path) {
            n += 1
            let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
            target = folder.appending(path: ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
        }
        downloads[ObjectIdentifier(download)] = (target, response.url)
        log.info("download to \(target.path, privacy: .public)")
        return target
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let (file, source) = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        // Mark it as downloaded from the web so Gatekeeper checks it before it can run.
        var quarantine: [String: Any] = [kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload, kLSQuarantineAgentNameKey as String: "Mako"]
        if let source { quarantine[kLSQuarantineDataURLKey as String] = source }
        do { try (file as NSURL).setResourceValue(quarantine, forKey: .quarantinePropertiesKey) }
        catch { log.error("could not quarantine \(file.path, privacy: .public): \(error.localizedDescription, privacy: .public)") }
        log.info("downloaded \(file.path, privacy: .public)")
        // Bounces the Downloads stack in the Dock, as Safari does.
        DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: file.path)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloads[ObjectIdentifier(download)] = nil
        log.error("download failed: \(error.localizedDescription, privacy: .public)")
        NSSound.beep()
    }

    /// Only web links are reopened by Mako. Reopening file: or other schemes ourselves would
    /// skip the checks WebKit applies to a page-initiated navigation.
    private func isWeb(_ url: URL) -> Bool { ["http", "https"].contains(url.scheme?.lowercased() ?? "") }

    private func sameDocument(_ a: URL, _ b: URL?) -> Bool {
        func bare(_ u: URL?) -> String? { u?.absoluteString.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) }
        return a.fragment != nil && bare(a) == bare(b)
    }

    /// A target=_blank link is a followed link too. Script popups get a real window built
    /// from WebKit's configuration, which is what keeps window.opener alive for OAuth.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures features: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, isWeb(url), let parent = id(of: webView), (webView as? PageView)?.claimBackground() == true {
            log.info("child of \(parent) \(url.absoluteString, privacy: .public) (middle-click)")
            apply("open_child", ["parent": parent, "url": url.absoluteString, "select": false])
            return nil
        }
        guard action.navigationType != .linkActivated else {
            if let url = action.request.url {
                if isWeb(url), let parent = id(of: webView) {
                    apply("open_child", ["parent": parent, "url": url.absoluteString])
                } else {
                    webView.load(action.request)
                }
            }
            return nil
        }
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.navigationDelegate = self
        popup.uiDelegate = self
        let size = NSSize(width: features.width?.doubleValue ?? 520, height: features.height?.doubleValue ?? 680)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = popup
        w.delegate = self
        w.setAccessibilityIdentifier("mako.popup")
        popupObservations.append(popup.observe(\.title) { [weak w] p, _ in MainActor.assumeIsolated { w?.title = p.title ?? "" } })
        w.center()
        if Self.background { w.orderBack(nil) } else { w.makeKeyAndOrderFront(nil) }
        popups.append(w)
        log.info("popup \(action.request.url?.absoluteString ?? "", privacy: .public)")
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        popups.first { $0.contentView === webView }?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, popups.contains(closing) else { return }
        popups.removeAll { $0 === closing }
        // Hand focus back to the page that opened the sign-in.
        if !Self.background { window.makeKeyAndOrderFront(nil) }
        window.makeFirstResponder(omnibox.isHidden ? shown : field)
    }

    func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        Perf.firstPage()
        // Read the page's declared icon from Mako's own script world, out of the page's reach.
        if id(of: webView) != nil, let page = webView.url {
            webView.evaluateJavaScript(Favicons.script, in: nil, in: .defaultClient) { [weak self] result in
                MainActor.assumeIsolated {
                    if case .success(let href as String) = result, let icon = URL(string: href) { self?.favicons.pageDeclared(icon, on: page) }
                }
            }
        }
        log.info("loaded page \(self.id(of: webView).map(String.init) ?? "popup", privacy: .public): \(webView.title ?? "", privacy: .public)")
    }

    func webView(_ webView: WKWebView, didFail _: WKNavigation!, withError error: Error) { showError(error, in: webView) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) { showError(error, in: webView) }

    private func showError(_ error: Error, in webView: WKWebView) {
        let e = error as NSError
        // Cancelled (-999) and "frame load interrupted" (102, e.g. downloads) are not failures worth a page.
        guard e.code != NSURLErrorCancelled, e.code != 102 else { return }
        webView.loadHTMLString(Self.page("Can’t open this page", e.localizedDescription), baseURL: nil)
    }

    static func blockPage(_ reason: String) -> String { page("Not now.", reason + " Back to work.") }

    static func page(_ title: String, _ body: String) -> String {
        let esc = { (s: String) in s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") }
        return """
            <title>\(esc(title))</title><meta name="color-scheme" content="light dark">
            <body style="font:16px -apple-system;display:grid;place-items:center;height:90vh;margin:0">
            <div style="text-align:center"><h1 style="font-weight:600;margin:0 0 8px">\(esc(title))</h1>
            <p style="opacity:.6">\(esc(body))</p></div>
            """
    }
}

/// The omnibox's one line. It never wraps: a long address shrinks the font from 18 pt
/// to as small as 11 pt to fit, and past that scrolls sideways.
final class OmniboxField: NSTextField {
    static func font(_ size: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: size, weight: .regular) }
    static let height = ceil(NSLayoutManager().defaultLineHeight(for: font(18))) + 2

    override class var cellClass: AnyClass? {
        get { CenteredCell.self }
        set {}
    }

    /// 18 × room ÷ width at 18 pt, kept within 11…18 and in half points so typing does not
    /// resize it on every key.
    func fitFont() {
        let text = stringValue.isEmpty ? placeholderString ?? "" : stringValue
        let width = (text as NSString).size(withAttributes: [.font: Self.font(18)]).width
        let room = bounds.width - 8
        let size = width > room && room > 0 ? max(11, (36 * room / width).rounded(.down) / 2) : 18
        guard font?.pointSize != size else { return }
        font = Self.font(size)
        // The field editor keeps its own font while editing.
        (currentEditor() as? NSTextView)?.font = font
    }
}

/// Centres a smaller font in the fixed-height omnibox line; the field editor follows drawingRect.
private final class CenteredCell: NSTextFieldCell {
    private func centered(_ rect: NSRect) -> NSRect {
        let height = cellSize(forBounds: rect).height
        return NSRect(x: rect.minX, y: rect.minY + max(0, (rect.height - height) / 2), width: rect.width, height: min(height, rect.height))
    }
    override func drawingRect(forBounds rect: NSRect) -> NSRect { centered(super.drawingRect(forBounds: rect)) }
}
