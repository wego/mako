import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var browser: Browser!
    private var pending: [URL] = []

    func applicationDidFinishLaunching(_: Notification) {
        Core.ensureConfig()
        browser = Browser(restoring: Core.loadSession())
        NSApp.mainMenu = makeMenu()
        CommandLine.arguments.dropFirst().compactMap(URL.init(string:)).filter { $0.scheme != nil }.forEach(browser.open)
        pending.forEach(browser.open)
        NSApp.activate()
        Perf.interactiveAfterLaunch()
    }

    func application(_: NSApplication, open urls: [URL]) {
        guard let browser else { return pending += urls }
        urls.forEach(browser.open)
        browser.window.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { true }

    func applicationWillTerminate(_: Notification) { Core.save(browser.session) }

    private func makeMenu() -> NSMenu {
        func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = NSMenu(title: title)
            items.forEach(item.submenu!.addItem)
            return item
        }
        func item(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.tag = tag
            return i
        }
        let main = NSMenu()
        let tabs = NSMenuItem(title: "Tabs", action: nil, keyEquivalent: "")
        tabs.submenu = browser.tabsMenu
        [
            menu("Mako", [
                item("Settings…", #selector(Browser.openConfig), ","),
                .separator(),
                item("Hide Mako", #selector(NSApplication.hide), "h"),
                item("Quit Mako", #selector(NSApplication.terminate), "q"),
            ]),
            menu("File", [
                item("New Tab", #selector(Browser.newTabAction), "t"),
                item("Open Location…", #selector(Browser.openLocation), "l"),
                item("Close Tab", #selector(Browser.closeTab), "w"),
            ]),
            menu("Edit", [
                item("Undo", Selector(("undo:")), "z"),
                item("Redo", Selector(("redo:")), "z", [.command, .shift]),
                .separator(),
                item("Cut", #selector(NSText.cut), "x"),
                item("Copy", #selector(NSText.copy), "c"),
                item("Paste", #selector(NSText.paste), "v"),
                item("Select All", #selector(NSText.selectAll), "a"),
            ]),
            menu("View", [
                item("Reload", #selector(Browser.reload), "r"),
                item("Zoom In", #selector(Browser.zoomIn), "="),
                item("Zoom Out", #selector(Browser.zoomOut), "-"),
                item("Actual Size", #selector(Browser.zoomReset), "0"),
                .separator(),
                item("Developer Console", #selector(Browser.toggleConsole), "c", [.command, .option]),
                item("Enter Full Screen", #selector(NSWindow.toggleFullScreen), "f", [.command, .control]),
            ]),
            menu("History", [
                item("Back", #selector(Browser.back), "["),
                item("Forward", #selector(Browser.forward), "]"),
            ]),
            tabs,
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
