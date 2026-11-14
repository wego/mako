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
        ([.command, .control], "s"),
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
    /// Hidden leaves only the page; the pointer at the window's left edge slides the sidebar
    /// over the page (peeking) until it leaves again.
    enum SidebarState { case shown, hidden, peeking }

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
    /// Page dialogs shown per web view, and web views the person has silenced.
    private var dialogsShown: [ObjectIdentifier: Int] = [:]
    private var silenced: Set<ObjectIdentifier> = []
    /// The navigation the person last started from Mako (address bar, Back, Forward, Reload) per
    /// web view, kept by identity: a same-document Back never commits, so a bare mark would
    /// wait for the page's next reload.
    private var userLoads: [ObjectIdentifier: WKNavigation] = [:]
    private let webConfig = WKWebViewConfiguration()
    private let container = NSView()
    private let sidebar = Sidebar()
    private let favicons = Favicons()
    private let divider = DividerView()
    private var sidebarWidth: NSLayoutConstraint!
    private var sidebarLeading: NSLayoutConstraint!
    private var pageBesideSidebar: NSLayoutConstraint!
    private var pageFullWidth: NSLayoutConstraint!
    private(set) var sidebarState = SidebarState.shown
    private let edge = EdgeView()
    private let topStrip = WindowDragStrip()
    private let blank = NSImageView()
    /// Kept in sync on every change so the AX tree never depends on the menu being opened.
    let trailsMenu = NSMenu(title: "Trails")
    /// Everything the open omnibox puts over the window: the scrim, the card and the panel.
    private let omniLayer = NSView()
    private let scrim = Scrim()
    private let card = OmniCard()
    private let omnibox = NSView()
    private let glyph = OmniGlyph()
    private let field = OmniboxField()
    /// The field's own editor, so its caret and selection take the omnibox's colour without
    /// recolouring the window's shared one (rename fields use that).
    private let omniEditor: NSTextView = {
        let editor = NSTextView()
        editor.isFieldEditor = true
        return editor
    }()
    private let hint = NSTextField(labelWithString: "")
    /// An error or message for the open omnibox; it goes when the omnibox next opens.
    private var omniMessage: String?
    private var omniboxOpen: Bool { !omniLayer.isHidden }
    private var folderWatch: DispatchSourceFileSystemObject?
    private var fileWatch: DispatchSourceFileSystemObject?

    override init() {
        window = MenuFirstWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        super.init()
        window.delegate = self
        window.tabbingMode = .disallowed
        // No title bar of its own: the traffic lights sit on the sidebar, the page runs to the
        // top edge. The title still names the window in the Window list and Mission Control.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
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
        folderWatch = watch(Core.configURL.deletingLastPathComponent())
        fileWatch = watch(Core.configURL)
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
        sidebar.onPlace = { [unowned self] in if apply("place", ["id": $0, "target": $1, "place": $2.rawValue]) != nil { NSSound.beep() } }
        sidebar.iconFor = { [unowned self] in favicons.icon(for: $0.url) }
        sidebar.onOpenConfig = { [unowned self] in openConfig(nil) }
        favicons.onChange = { [unowned self] in sidebar.refreshIcons() }
        divider.onSet = { [unowned self] in setSidebarWidth($0) }

        sidebar.onExit = { [unowned self] in if sidebarState == .peeking { setSidebar(.hidden) } }
        sidebar.onToggleSidebar = { [unowned self] in toggleSidebar(nil) }
        edge.onEnter = { [unowned self] in if sidebarState == .hidden { setSidebar(.peeking) } }

        let root = NSView()
        // The page first, so a peeking sidebar slides in above it.
        for view in [container, sidebar, divider] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
            view.topAnchor.constraint(equalTo: root.topAnchor).isActive = true
            view.bottomAnchor.constraint(equalTo: root.bottomAnchor).isActive = true
        }
        window.contentView = root
        if let guide = window.contentLayoutGuide as? NSLayoutGuide { sidebar.pinRows(below: guide.topAnchor) }
        for view in [edge, topStrip] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        // A fifth of the window to start with; a dragged width is remembered.
        let saved = UserDefaults.standard.double(forKey: "sidebarWidth")
        sidebarWidth = sidebar.widthAnchor.constraint(equalToConstant: saved > 0 ? saved : min(max(window.frame.width * 0.2, 200), 320))
        sidebarLeading = sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor)
        pageBesideSidebar = container.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor)
        pageFullWidth = container.leadingAnchor.constraint(equalTo: root.leadingAnchor)
        NSLayoutConstraint.activate([
            blank.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            blank.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            blank.widthAnchor.constraint(equalToConstant: 128),
            blank.heightAnchor.constraint(equalToConstant: 128),
            sidebarWidth,
            sidebarLeading,
            pageBesideSidebar,
            // The divider is wider than the line it draws so it is easy to grab.
            divider.centerXAnchor.constraint(equalTo: sidebar.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 7),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 400),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
            edge.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            edge.topAnchor.constraint(equalTo: root.topAnchor),
            edge.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            edge.widthAnchor.constraint(equalToConstant: 6),
            topStrip.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topStrip.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            topStrip.topAnchor.constraint(equalTo: root.topAnchor),
            topStrip.heightAnchor.constraint(equalToConstant: 8),
        ])
        root.addSubview(divider, positioned: .above, relativeTo: nil)
        setSidebar(UserDefaults.standard.bool(forKey: "sidebarHidden") ? .hidden : .shown)
    }

    /// Shown: the sidebar beside the page, with the traffic lights on it. Hidden: only the page,
    /// a strip along its top edge to drag the window by. Peeking: the sidebar over the page.
    private func setSidebar(_ state: SidebarState) {
        let from = sidebarState
        sidebarState = state
        if state != .peeking { UserDefaults.standard.set(state == .hidden, forKey: "sidebarHidden") }
        // Off before on, so the two never hold at once.
        let (on, off) = state == .shown ? (pageBesideSidebar!, pageFullWidth!) : (pageFullWidth!, pageBesideSidebar!)
        off.isActive = false
        on.isActive = true
        divider.isHidden = state != .shown
        edge.isHidden = state != .hidden
        topStrip.isHidden = state != .hidden
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = state == .hidden
        }
        sidebar.floats = state == .peeking
        sidebar.setPeeking(state == .peeking)
        let slid = state == .hidden ? -sidebarWidth.constant : 0
        if state == .hidden, from == .shown {
            sidebarLeading.constant = slid
            sidebar.isHidden = true
        } else if from != state {
            sidebar.isHidden = false
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.18
                context.allowsImplicitAnimation = true
                sidebarLeading.animator().constant = slid
                window.contentView?.layoutSubtreeIfNeeded()
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.sidebarState == .hidden else { return }
                    self.sidebar.isHidden = true
                }
            })
        } else {
            sidebarLeading.constant = slid
            sidebar.isHidden = state == .hidden
        }
        NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items)
            .first { $0.action == #selector(toggleSidebar(_:)) }?.title = sidebarMenuTitle
    }

    var sidebarMenuTitle: String { sidebarState == .shown ? "Hide Sidebar" : "Show Sidebar" }

    @objc func toggleSidebar(_: Any?) {
        setSidebar(sidebarState == .shown ? .hidden : .shown)
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
                container.addSubview(view)
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
        sidebar.update(store.rows)
        showConfig()
        rebuildTrailsMenu()
        if !omniboxOpen, let view { window.makeFirstResponder(view) }
    }

    /// What the window shows from the config: the cap and config notes, the omnibox status.
    private func showConfig() {
        if omniboxOpen { updateHint() }
        sidebar.showLoad(trails: store.rows.filter { $0.depth == 0 }.count, max: Core.maxTrails)
        sidebar.showConfigIssue(Core.configError)
    }

    /// Editors and Settings mostly save the config by renaming a new file over it, which only
    /// its folder sees; an in-place save only the file sees. A rename leaves the file watch on
    /// the replaced file, so it is renewed on every change.
    @objc private func configChanged() {
        fileWatch?.cancel()
        fileWatch = watch(Core.configURL)
        showConfig()
    }

    /// Calls configChanged once a burst of writes to the file or folder at `url` settles.
    private func watch(_ url: URL) -> DispatchSourceFileSystemObject? {
        let fd = Darwin.open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(self.configChanged), object: nil)
                self.perform(#selector(self.configChanged), with: nil, afterDelay: 0.1)
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        return source
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
        dialogsShown[ObjectIdentifier(view)] = nil
        silenced.remove(ObjectIdentifier(view))
        userLoads[ObjectIdentifier(view)] = nil
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
        field.textColor = .ink
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
        hint.textColor = .caution
        hint.lineBreakMode = .byTruncatingTail
        hint.maximumNumberOfLines = 0

        let line = NSStackView(views: [glyph, field])
        line.spacing = 10
        line.distribution = .fill
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        let stack = NSStackView(views: [line, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        omnibox.addSubview(stack)
        scrim.onDismiss = { [unowned self] in hideOmnibox() }
        guard let root = window.contentView else { return }
        omniLayer.isHidden = true
        for view in [omniLayer, scrim, card, omnibox] { view.translatesAutoresizingMaskIntoConstraints = false }
        omniLayer.addSubview(scrim)
        omniLayer.addSubview(card)
        omniLayer.addSubview(omnibox)
        // Over everything, the sidebar too: while it is open, the omnibox is the window's one task.
        root.addSubview(omniLayer, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            omniLayer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            omniLayer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            omniLayer.topAnchor.constraint(equalTo: root.topAnchor),
            omniLayer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scrim.leadingAnchor.constraint(equalTo: omniLayer.leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: omniLayer.trailingAnchor),
            scrim.topAnchor.constraint(equalTo: omniLayer.topAnchor),
            scrim.bottomAnchor.constraint(equalTo: omniLayer.bottomAnchor),
            card.leadingAnchor.constraint(equalTo: omnibox.leadingAnchor, constant: -OmniCard.inset),
            card.trailingAnchor.constraint(equalTo: omnibox.trailingAnchor, constant: OmniCard.inset),
            card.topAnchor.constraint(equalTo: omnibox.topAnchor, constant: -OmniCard.inset),
            card.bottomAnchor.constraint(equalTo: omnibox.bottomAnchor, constant: OmniCard.inset),
            stack.leadingAnchor.constraint(equalTo: omnibox.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: omnibox.trailingAnchor),
            stack.topAnchor.constraint(equalTo: omnibox.topAnchor),
            stack.bottomAnchor.constraint(equalTo: omnibox.bottomAnchor),
            omnibox.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            omnibox.topAnchor.constraint(equalTo: container.topAnchor, constant: 80),
            omnibox.widthAnchor.constraint(equalTo: container.widthAnchor, multiplier: 0.7),
            line.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -34),
            // The 18 pt line height at every font size, so the panel never jumps while typing.
            field.heightAnchor.constraint(equalToConstant: OmniboxField.height),
        ])
    }

    private func showOmnibox(for target: OmniTarget, text: String? = nil) {
        omniTarget = target
        field.stringValue = text ?? ""
        let purpose = switch target {
        case .current: store.active == nil ? "New trail – search or enter address" : "This page – search or enter address; Option-Return opens it beside this page"
        case .newTrail: "New trail – search or enter address"
        case .child: "New page beneath this one – search or enter address"
        case .find: "Find in this page"
        }
        field.setAccessibilityLabel(purpose)
        let look = look(for: target)
        card.look = look
        glyph.look = look
        field.placeholderString = look == .find ? "Find in page" : "Search or enter address"
        let accent = look.slot.map(NSColor.trail) ?? .ink
        omniEditor.insertionPointColor = accent
        omniEditor.selectedTextAttributes = [.backgroundColor: accent.withAlphaComponent(0.3), .foregroundColor: NSColor.ink]
        omniMessage = nil
        updateHint()
        omniLayer.isHidden = false
        window.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        omniLayer.superview?.layoutSubtreeIfNeeded()
        field.fitFont()
    }

    /// The trail Enter lands in: the active one for this page or a page beneath it, the
    /// colour the next trail would get for a new one.
    private func look(for target: OmniTarget) -> OmniLook {
        switch target {
        case .current: store.active.map { .page($0.color) } ?? .newTrail(store.nextColor)
        case .newTrail: .newTrail(store.nextColor)
        case .child(let parent): .child(store.rows.first { $0.id == parent }?.color ?? store.nextColor)
        case .find: .find
        }
    }

    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        (client as AnyObject?) === field ? omniEditor : nil
    }

    func controlTextDidChange(_ note: Notification) {
        if note.object as? NSTextField === field { field.fitFont() }
    }

    /// The status line shows only an error or message: the omnibox's own, else the config's.
    private func updateHint(message: String? = nil) {
        if let message { omniMessage = message }
        let text = omniMessage ?? Core.configError
        hint.stringValue = text ?? ""
        hint.isHidden = text == nil
    }

    private func hideOmnibox() {
        omniLayer.isHidden = true
        if let shown { window.makeFirstResponder(shown) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.cancelOperation(_:)): hideOmnibox()
        // ⌥Return, which a field would otherwise take as a literal newline.
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)): enter(beside: true)
        default: return false
        }
        return true
    }

    @objc func omniboxEntered(_: Any?) { enter(beside: false) }

    /// `beside`: an address for this page opens in a new page next to it instead of replacing it.
    private func enter(beside: Bool) {
        guard omniboxOpen else { return }
        if case .find = omniTarget { return findNext(nil) }
        guard let url = Core.resolve(field.stringValue) else { return hideOmnibox() }
        var error: String?
        switch omniTarget {
        case .current:
            if beside, let active = store.active {
                error = store.apply("open_sibling", ["of": active.id, "url": url.absoluteString])
            } else if shown != nil {
                userLoad { $0.load(URLRequest(url: url)) }
            } else {
                error = store.apply("open_trail", ["url": url.absoluteString])
            }
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
        omniLayer.isHidden = true
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
    @objc func back(_: Any?) { userLoad { $0.goBack() } }
    @objc func forward(_: Any?) { userLoad { $0.goForward() } }
    @objc func reload(_: Any?) { userLoad { $0.reload() } }
    private func userLoad(_ go: (WKWebView) -> WKNavigation?) {
        guard let shown else { return }
        userLoads[ObjectIdentifier(shown)] = go(shown)
    }
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
            self?.omniMessage = result.matchFound ? nil : "Not found"
            self?.updateHint()
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
    /// The name is edited in its sidebar row, so a hidden sidebar comes back for it.
    @objc func renamePage(_: Any?) {
        guard let id = store.active?.id else { return }
        if sidebarState == .hidden { setSidebar(.shown) }
        window.contentView?.layoutSubtreeIfNeeded()
        sidebar.beginRename(id)
    }

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
            // The download is the navigation a replayed middle-click started; the next one stays in front.
            _ = (webView as? PageView)?.claimBackground()
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
        // MAKO_DOWNLOADS lets verification runs keep their downloads out of the person's Downloads.
        let folder = ProcessInfo.processInfo.environment["MAKO_DOWNLOADS"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
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
        if let popup = closing.contentView {
            dialogsShown[ObjectIdentifier(popup)] = nil
            silenced.remove(ObjectIdentifier(popup))
            userLoads[ObjectIdentifier(popup)] = nil
        }
        // Hand focus back to the page that opened the sign-in.
        if !Self.background { window.makeKeyAndOrderFront(nil) }
        window.makeFirstResponder(omniboxOpen ? field : shown)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        _ = await ask(message, from: frame, in: webView, cancellable: false)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await ask(message, from: frame, in: webView, cancellable: true) != nil
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        let input = NSTextField(string: defaultText ?? "")
        input.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        input.setAccessibilityIdentifier("mako.dialog.field")
        return await ask(prompt, from: frame, in: webView, cancellable: true, input: input)
    }

    /// A page dialog as a sheet on the page's own window. nil when cancelled.
    private func ask(_ message: String, from frame: WKFrameInfo, in webView: WKWebView,
                     cancellable: Bool, input: NSTextField? = nil) async -> String? {
        let origin = frame.securityOrigin
        let host = origin.host.isEmpty ? "This page" : origin.port == 0 ? origin.host : "\(origin.host):\(origin.port)"
        let page = ObjectIdentifier(webView)
        // A page in a trail that isn't shown has no window; answering for it, as WebKit
        // would, beats pulling the person to a page they didn't pick.
        guard let window = webView.window, !silenced.contains(page) else {
            log.info("dialog from \(host, privacy: .public) dismissed")
            return nil
        }
        dialogsShown[page, default: 0] += 1
        let alert = NSAlert()
        // The origin takes the bold line so page text cannot pose as another site.
        alert.messageText = frame.isMainFrame ? host : "\(host) (embedded in this page)"
        alert.informativeText = message
        alert.addButton(withTitle: "OK").setAccessibilityIdentifier("mako.dialog.ok")
        if cancellable { alert.addButton(withTitle: "Cancel").setAccessibilityIdentifier("mako.dialog.cancel") }
        if let input {
            alert.accessoryView = input
            alert.window.initialFirstResponder = input
        }
        // A sheet blocks the whole window, so a page looping on alert() must be stoppable.
        if dialogsShown[page, default: 0] > 1 {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don’t show more dialogs from this page"
            alert.suppressionButton?.setAccessibilityIdentifier("mako.dialog.silence")
        }
        let answer = await alert.beginSheetModal(for: window)
        if alert.suppressionButton?.state == .on { silenced.insert(page) }
        guard answer == .alertFirstButtonReturn else { return nil }
        return input?.stringValue ?? ""
    }

    /// Only a load the person started lifts silencing: a page that reloads or redirects
    /// itself between alerts would otherwise reset its own count and loop again.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let started = userLoads[ObjectIdentifier(webView)], started === navigation else { return }
        userLoads[ObjectIdentifier(webView)] = nil
        dialogsShown[ObjectIdentifier(webView)] = nil
        silenced.remove(ObjectIdentifier(webView))
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

/// Dims the window under the open omnibox. A click on it closes the omnibox and goes no
/// further: on a dimmed window it reads as dismissing, not as a click on the link beneath.
@MainActor
final class Scrim: NSView {
    var onDismiss: () -> Void = {}

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("mako.omnibox.scrim")
        setAccessibilityLabel("Close address bar")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.scrim.setFill()
        dirtyRect.intersection(bounds).fill()
    }
    override func mouseDown(with event: NSEvent) { onDismiss() }
    override func rightMouseDown(with event: NSEvent) { onDismiss() }
    override func otherMouseDown(with event: NSEvent) { onDismiss() }
    override var mouseDownCanMoveWindow: Bool { false }
    override func accessibilityPerformPress() -> Bool {
        onDismiss()
        return true
    }
}

/// What the omnibox looks like: the trail Enter lands in, and how (a new trail, this page, a
/// page beneath it), or find, which belongs to no trail.
enum OmniLook: Equatable {
    case newTrail(Int), page(Int), child(Int), find

    var slot: Int? {
        switch self {
        case .newTrail(let slot), .page(let slot), .child(let slot): slot
        case .find: nil
        }
    }
}

/// The omnibox panel as a raised sidebar card: the trail's tinted paper inside a 3 pt ring
/// in the trail's colour. Find gets plain paper and a thin ink ring. A deep shadow lifts
/// either over any page in either appearance.
@MainActor
final class OmniCard: NSView {
    static let inset: CGFloat = 3
    var look = OmniLook.find { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 28
        layer?.shadowOffset = CGSize(width: 0, height: -10)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        guard let layer else { return }
        layer.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 18 + Self.inset, cornerHeight: 18 + Self.inset, transform: nil)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.shadowColor = NSColor.black.withAlphaComponent(0.45).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() { needsLayout = true }

    override func draw(_ dirtyRect: NSRect) {
        let panel = bounds.insetBy(dx: Self.inset, dy: Self.inset)
        let (paper, ink, width): (NSColor, NSColor, CGFloat) = look.slot.map { (.card($0), .trail($0), Self.inset) }
            ?? (.sidebarPaper, .ink.withAlphaComponent(0.6), 1.5)
        paper.setFill()
        NSBezierPath(roundedRect: panel, xRadius: 18, yRadius: 18).fill()
        let ring = NSBezierPath(roundedRect: panel.insetBy(dx: -width / 2, dy: -width / 2), xRadius: 18 + width / 2, yRadius: 18 + width / 2)
        ring.lineWidth = width
        ink.setStroke()
        ring.stroke()
    }
}

/// Leads the omnibox field with where Enter lands, drawn as the sidebar draws it: a trail's
/// root dot for a new trail, a plain dot for this page, a branch for a page beneath. Find
/// gets a magnifying glass.
@MainActor
final class OmniGlyph: NSView {
    var look = OmniLook.find { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: 20, height: 20) }

    override func draw(_ dirtyRect: NSRect) {
        let mid = NSPoint(x: bounds.midX, y: bounds.midY)
        func dot(_ radius: CGFloat, _ color: NSColor, at center: NSPoint) {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
        }
        switch look {
        case .newTrail(let slot):
            dot(8, NSColor.trail(slot).withAlphaComponent(0.22), at: mid)
            dot(5, .trail(slot), at: mid)
        case .page(let slot):
            dot(5, .trail(slot), at: mid)
        case .child(let slot):
            let branch = NSBezierPath()
            branch.move(to: NSPoint(x: mid.x - 5, y: mid.y + 9))
            branch.appendArc(from: NSPoint(x: mid.x - 5, y: mid.y - 2), to: NSPoint(x: mid.x + 3, y: mid.y - 2), radius: 6)
            branch.line(to: NSPoint(x: mid.x + 3, y: mid.y - 2))
            branch.lineWidth = 1.5
            NSColor.trail(slot).withAlphaComponent(0.85).setStroke()
            branch.stroke()
            dot(3.5, .trail(slot), at: NSPoint(x: mid.x + 5.5, y: mid.y - 2))
        case .find:
            let glass = NSBezierPath(ovalIn: NSRect(x: mid.x - 7, y: mid.y - 2.5, width: 10, height: 10))
            glass.move(to: NSPoint(x: mid.x + 1.6, y: mid.y - 1.1))
            glass.line(to: NSPoint(x: mid.x + 6.5, y: mid.y - 6))
            glass.lineWidth = 1.75
            glass.lineCapStyle = .round
            NSColor.ink.withAlphaComponent(0.6).setStroke()
            glass.stroke()
        }
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
