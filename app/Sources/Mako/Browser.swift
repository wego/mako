import AppKit
import WebKit
import os

let log = Logger(subsystem: "com.chuyeow.mako", category: "browser")

/// Offers only Mako-owned ⌘-shortcuts to the main menu first so pages cannot hijack
/// tab and omnibox controls. Editing and navigation shortcuts keep AppKit's order.
final class MenuFirstWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if let key = event.charactersIgnoringModifiers,
           (mods == .command && ["t", "w", "l", ",", "1", "2", "3", "4", "5", "6", "7", "8", "9"].contains(key))
               || (mods == [.command, .option] && key == "c"),
           NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// One window, a few tabs, no tab bar. ⌘L summons the omnibox, which also lists tabs.
@MainActor
final class Browser: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, NSTextFieldDelegate {
    let window: NSWindow
    private var tabs: [WKWebView] = []
    private var active = 0
    private var observations: [NSKeyValueObservation] = []
    private let webConfig = WKWebViewConfiguration()
    private let container = NSView()
    private let blank = NSImageView()
    /// Kept in sync on every tab change so ⌘1–9 and the AX tree never depend on the menu being opened.
    let tabsMenu = NSMenu(title: "Tabs")
    private let omnibox = NSGlassEffectView()
    private let field = NSTextField()
    private let hint = NSTextField(labelWithString: "")

    init(restoring session: Session?) {
        window = MenuFirstWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        super.init()
        window.delegate = self
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName("main")
        window.contentView = container
        container.setAccessibilityElement(true)
        container.setAccessibilityRole(.group)
        container.setAccessibilityIdentifier("mako.page")
        container.setAccessibilityLabel("Page")
        blank.setAccessibilityIdentifier("mako.blank")
        blank.setAccessibilityLabel("New tab")
        blank.image = NSApp.applicationIconImage
        blank.imageScaling = .scaleProportionallyUpOrDown
        blank.alphaValue = 0.9
        blank.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(blank)
        NSLayoutConstraint.activate([
            blank.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            blank.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            blank.widthAnchor.constraint(equalToConstant: 128),
            blank.heightAnchor.constraint(equalToConstant: 128),
        ])
        webConfig.preferences.isElementFullscreenEnabled = true
        webConfig.preferences.setValue(true, forKey: "developerExtrasEnabled")
        buildOmnibox()
        let restored = session?.tabs.prefix(Core.maxTabs) ?? []
        if restored.isEmpty {
            newTab()
            window.makeKeyAndOrderFront(nil)
            showOmnibox()
        } else {
            for url in restored {
                newTab()
                web.load(URLRequest(url: url))
            }
            select(min(max(session?.active ?? 0, 0), tabs.count - 1))
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// Tabs without an http(s) page (blank, block, error) are not worth restoring.
    var session: Session {
        var urls: [URL] = []
        var activeIndex = 0
        for (i, tab) in tabs.enumerated() {
            guard let url = page(tab) else { continue }
            if i == active { activeIndex = urls.count }
            urls.append(url)
        }
        return Session(tabs: urls, active: activeIndex)
    }

    private var web: WKWebView { tabs[active] }
    /// Current page, ignoring the blank/block/error pages Mako loads itself.
    private var pageURL: URL? { page(web) }

    private func page(_ webView: WKWebView) -> URL? {
        guard let url = webView.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    private func tabLabel(_ webView: WKWebView) -> String {
        if let title = webView.title, !title.isEmpty { return title }
        return webView.url?.host() ?? "New Tab"
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
        hint.setAccessibilityLabel("Tabs and status")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20)
        field.placeholderString = "Search or enter address"
        field.delegate = self
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
            omnibox.widthAnchor.constraint(equalTo: container.widthAnchor, multiplier: 0.6),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
        ])
    }

    func showOmnibox(text: String? = nil, message: String? = nil) {
        field.stringValue = text ?? pageURL?.absoluteString ?? ""
        updateHint(message: message)
        omnibox.isHidden = false
        container.addSubview(omnibox, positioned: .above, relativeTo: nil)
        window.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    private func updateHint(message: String? = nil) {
        let tabList = tabs.enumerated().map { i, t in
            "\(i == active ? "▸" : " ")⌘\(i + 1) \(tabLabel(t))"
        }
        hint.stringValue = ([message ?? Core.configError].compactMap { $0 } + tabList + ["\(tabs.count)/\(Core.maxTabs) tabs"])
            .joined(separator: "\n")
    }

    private func hideOmnibox() {
        omnibox.isHidden = true
        window.makeFirstResponder(web)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.cancelOperation(_:)):
            hideOmnibox()
        case #selector(NSResponder.insertNewline(_:)):
            if let url = Core.resolve(field.stringValue) { web.load(URLRequest(url: url)) }
            hideOmnibox()
        default:
            return false
        }
        return true
    }

    // MARK: Tabs

    @discardableResult
    private func newTab() -> Bool {
        guard tabs.count < Core.maxTabs else {
            log.info("tab cap \(Core.maxTabs) reached")
            NSSound.beep()
            showOmnibox(message: "Tab cap reached (\(Core.maxTabs)). Close one with ⌘W, or Enter to load here.")
            return false
        }
        let w = WKWebView(frame: .zero, configuration: webConfig)
        w.navigationDelegate = self
        w.uiDelegate = self
        w.allowsBackForwardNavigationGestures = true
        w.allowsMagnification = true
        w.isInspectable = true
        observations += [
            w.observe(\.title) { [weak self] _, _ in MainActor.assumeIsolated { self?.updateTabPresentation() } },
            w.observe(\.url) { [weak self] _, _ in MainActor.assumeIsolated { self?.updateTabPresentation() } },
            w.observe(\.isLoading) { [weak self] _, _ in MainActor.assumeIsolated { self?.updateTabPresentation() } },
        ]
        tabs.append(w)
        updateTabIdentifiers()
        select(tabs.count - 1)
        return true
    }

    private func select(_ i: Int) {
        guard tabs.indices.contains(i) else { return NSSound.beep() }
        tabs[active].removeFromSuperview()
        active = i
        web.frame = container.bounds
        web.autoresizingMask = [.width, .height]
        container.addSubview(web, positioned: .below, relativeTo: omnibox)
        updateTabPresentation()
        window.makeFirstResponder(omnibox.isHidden ? web : field)
    }

    private func updateTabPresentation() {
        guard !tabs.isEmpty else { return }
        window.title = tabLabel(web)
        window.subtitle = "\(active + 1)/\(tabs.count)"
        let isBlank = web.url == nil && !web.isLoading
        blank.isHidden = !isBlank
        web.isHidden = isBlank
        if !omnibox.isHidden { updateHint() }
        rebuildTabsMenu()
    }

    private func updateTabIdentifiers() {
        for (i, tab) in tabs.enumerated() {
            tab.setAccessibilityIdentifier("mako.tab.\(i + 1)")
        }
    }

    private func rebuildTabsMenu() {
        tabsMenu.removeAllItems()
        for (i, tab) in tabs.enumerated() {
            let item = NSMenuItem(title: tabLabel(tab), action: #selector(selectTab(_:)),
                                  keyEquivalent: i < 9 ? "\(i + 1)" : "")
            item.keyEquivalentModifierMask = .command
            item.target = self
            item.tag = i
            item.state = i == active ? .on : .off
            tabsMenu.addItem(item)
        }
    }

    /// Opens an external link: new tab if under the cap, otherwise ask before replacing.
    func open(_ url: URL) {
        if tabs.count == 1 && pageURL == nil {
            web.load(URLRequest(url: url))
            hideOmnibox()
        } else if tabs.count < Core.maxTabs {
            newTab()
            web.load(URLRequest(url: url))
            hideOmnibox()
        } else {
            showOmnibox(text: url.absoluteString, message: "Tab cap reached. Enter replaces this tab, Esc ignores.")
        }
    }

    // MARK: Menu actions

    @objc func newTabAction(_: Any?) { if newTab() { showOmnibox(text: "") } }
    @objc func openLocation(_: Any?) { showOmnibox() }
    @objc func back(_: Any?) { web.goBack() }
    @objc func forward(_: Any?) { web.goForward() }
    @objc func reload(_: Any?) { web.reload() }
    @objc func zoomIn(_: Any?) { web.pageZoom += 0.1 }
    @objc func zoomOut(_: Any?) { web.pageZoom = max(0.3, web.pageZoom - 0.1) }
    @objc func zoomReset(_: Any?) { web.pageZoom = 1 }
    @objc func selectTab(_ sender: NSMenuItem) { select(sender.tag) }
    @objc func openConfig(_: Any?) { NSWorkspace.shared.open(Core.configURL) }

    /// WebKit has no public API to open the Web Inspector; this is the private
    /// _WKInspector that Safari's ⌥⌘C uses. Fine outside the App Store.
    @objc func toggleConsole(_: Any?) {
        guard let inspector = web.value(forKey: "_inspector") as? NSObject else { return NSSound.beep() }
        if inspector.value(forKey: "isVisible") as? Bool == true {
            inspector.perform(NSSelectorFromString("close"))
        } else {
            inspector.perform(NSSelectorFromString("showConsole"))
        }
    }

    @objc func closeTab(_: Any?) {
        let closing = tabs.remove(at: active)
        closing.removeFromSuperview()
        guard !tabs.isEmpty else {
            active = 0
            newTab()
            return showOmnibox(text: "")
        }
        active = min(active, tabs.count - 1)
        updateTabIdentifiers()
        select(active)
    }

    // MARK: Focus policy

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard action.targetFrame?.isMainFrame ?? true,
              let host = action.request.url?.host(),
              let reason = Core.blockReason(host: host)
        else {
            log.info("allow \(action.request.url?.absoluteString ?? "", privacy: .public)")
            return .allow
        }
        log.info("block \(host, privacy: .public): \(reason, privacy: .public)")
        webView.loadHTMLString(Self.blockPage(reason), baseURL: nil)
        return .cancel
    }

    /// target=_blank and window.open stay in the current tab.
    func webView(_ webView: WKWebView, createWebViewWith _: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures _: WKWindowFeatures) -> WKWebView? {
        webView.load(action.request)
        return nil
    }

    func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        log.info("loaded tab \(self.tabs.firstIndex(of: webView) ?? -1)/\(self.tabs.count): \(webView.title ?? "", privacy: .public)")
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
