import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var browser: Browser!
    let settings = Settings()
    private var pending: [URL] = []

    func applicationDidFinishLaunching(_: Notification) {
        Core.ensureConfig()
        browser = Browser()
        NSApp.mainMenu = makeMenu()
        CommandLine.arguments.dropFirst().compactMap(URL.init(string:)).filter { $0.scheme != nil }.forEach(browser.open)
        pending.forEach(browser.open)
        if !Browser.background { NSApp.activate() }
        Perf.interactiveAfterLaunch()
    }

    func application(_: NSApplication, open urls: [URL]) {
        guard let browser else { return pending += urls }
        urls.forEach(browser.open)
        if !Browser.background { browser.window.makeKeyAndOrderFront(nil) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { true }

    /// Trails are saved on every change; with restore off, nothing is kept for next time.
    func applicationWillTerminate(_: Notification) {
        if !Core.restoreSession { try? FileManager.default.removeItem(at: TrailStore.fileURL) }
    }

    private func makeMenu() -> NSMenu {
        func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = NSMenu(title: title)
            items.forEach(item.submenu!.addItem)
            return item
        }
        func item(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            // Browser's own actions name it as target, so they work (and accessibility
            // clients can press them) even when Mako is not the frontmost app.
            if browser.responds(to: action) { i.target = browser }
            if settings.responds(to: action) { i.target = settings }
            return i
        }
        let main = NSMenu()
        let trails = NSMenuItem(title: "Trails", action: nil, keyEquivalent: "")
        trails.submenu = browser.trailsMenu
        [
            menu("Mako", [
                item("About Mako", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
                .separator(),
                item("Settings…", #selector(Settings.show(_:)), "."),
                item("Edit Config File…", #selector(Browser.openConfig), ","),
                .separator(),
                item("Hide Mako", #selector(NSApplication.hide), "h"),
                item("Quit Mako", #selector(NSApplication.terminate), "q"),
            ]),
            menu("File", [
                item("New Trail", #selector(Browser.newTrail), "t"),
                item("New Page in Trail", #selector(Browser.newPage), "t", [.command, .option]),
                item("Open Location…", #selector(Browser.openLocation), "l"),
                .separator(),
                item("Close Page", #selector(Browser.closePage), "w"),
                item("Reopen Closed Page", #selector(Browser.reopenClosedPage), "t", [.command, .shift]),
            ]),
            menu("Edit", [
                item("Undo", Selector(("undo:")), "z"),
                item("Redo", Selector(("redo:")), "z", [.command, .shift]),
                .separator(),
                // Spelled out: #selector(NSText.copy) resolves to NSObject's -copy, which crashed.
                item("Cut", #selector(NSText.cut(_:)), "x"),
                item("Copy", #selector(NSText.copy(_:)), "c"),
                item("Paste", #selector(NSText.paste(_:)), "v"),
                item("Select All", #selector(NSText.selectAll(_:)), "a"),
                .separator(),
                item("Find…", #selector(Browser.findInPage), "f"),
                item("Find Next", #selector(Browser.findNext), "g"),
                item("Find Previous", #selector(Browser.findPrevious), "g", [.command, .shift]),
            ]),
            menu("View", [
                item("Reload", #selector(Browser.reload), "r"),
                item("Zoom In", #selector(Browser.zoomIn), "="),
                item("Zoom Out", #selector(Browser.zoomOut), "-"),
                item("Actual Size", #selector(Browser.zoomReset), "0"),
                .separator(),
                item(browser.sidebarMenuTitle, #selector(Browser.toggleSidebar), "s", [.command, .control]),
                .separator(),
                item("Developer Console", #selector(Browser.toggleConsole), "c", [.command, .option]),
                item("Enter Full Screen", #selector(NSWindow.toggleFullScreen), "f", [.command, .control]),
            ]),
            menu("History", [
                item("Back", #selector(Browser.back), "["),
                item("Forward", #selector(Browser.forward), "]"),
            ]),
            trails,
        ].forEach(main.addItem)
        return main
    }
}

// Browser actions route through the window delegate, which sits in the responder chain.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
