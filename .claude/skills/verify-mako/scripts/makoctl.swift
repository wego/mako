// Drives one Mako process by PID through the macOS accessibility API.
// Never targets an app by name, so a user's own Mako is never touched.
import AppKit
import ApplicationServices

func fail(_ msg: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(code)
}

func attr(_ e: AXUIElement, _ a: String) -> Any? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
}

func element(_ e: AXUIElement, _ a: String) -> AXUIElement? {
    guard let v = attr(e, a), CFGetTypeID(v as CFTypeRef) == AXUIElementGetTypeID() else { return nil }
    return (v as! AXUIElement)
}

func children(_ e: AXUIElement) -> [AXUIElement] { attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
func str(_ e: AXUIElement, _ a: String) -> String? { (attr(e, a) as? String).flatMap { $0.isEmpty ? nil : $0 } }

func line(_ e: AXUIElement) -> String {
    var parts = [str(e, kAXRoleAttribute) ?? "?"]
    for (k, a) in [("sub", kAXSubroleAttribute), ("id", kAXIdentifierAttribute), ("title", kAXTitleAttribute),
                   ("desc", kAXDescriptionAttribute), ("value", kAXValueAttribute)] {
        if let s = str(e, a) { parts.append("\(k)=\"\(s.prefix(80).replacingOccurrences(of: "\n", with: "⏎"))\"") }
    }
    if let on = attr(e, "AXMenuItemMarkChar") as? String, !on.isEmpty { parts.append("checked") }
    return parts.joined(separator: " ")
}

func dump(_ e: AXUIElement, _ depth: Int, _ max: Int, menus: Bool) {
    let role = str(e, kAXRoleAttribute)
    if !menus && role == kAXMenuBarRole { return }
    print(String(repeating: "  ", count: depth) + line(e))
    if depth < max { children(e).forEach { dump($0, depth + 1, max, menus: menus) } }
}

func find(_ e: AXUIElement, named name: String) -> AXUIElement? {
    if [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].contains(where: { str(e, $0) == name }),
       str(e, kAXRoleAttribute) != kAXStaticTextRole {
        return e
    }
    for c in children(e) { if let f = find(c, named: name) { return f } }
    return nil
}

func find(_ e: AXUIElement, id: String) -> AXUIElement? {
    if str(e, kAXIdentifierAttribute) == id { return e }
    for c in children(e) { if let f = find(c, id: id) { return f } }
    return nil
}

func submenu(_ app: AXUIElement, _ menu: String) -> AXUIElement {
    guard let bar = element(app, kAXMenuBarAttribute),
          let top = children(bar).first(where: { str($0, kAXTitleAttribute) == menu }),
          let sub = children(top).first else { fail("no menu \(menu)", 4) }
    return sub
}

// Reads and presses items without opening the menu; an open menu would swallow later keys.
func menuItem(_ app: AXUIElement, _ menu: String, _ item: String) -> AXUIElement {
    let items = children(submenu(app, menu))
    guard let hit = items.first(where: { str($0, kAXTitleAttribute) == item }) else {
        fail("no item \"\(item)\" in \(menu); have: \(items.compactMap { str($0, kAXTitleAttribute) })", 4)
    }
    return hit
}

let keyCodes: [String: CGKeyCode] = [
    "return": 36, "escape": 53, "tab": 48, "t": 17, "w": 13, "l": 37, "r": 15, "z": 6, "c": 8, "[": 33, "]": 30,
    "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "=": 24, "-": 27, "0": 29, ",": 43,
]

func post(_ pid: pid_t, key: CGKeyCode, flags: CGEventFlags = [], text: String? = nil, settle: Bool = true) {
    for down in [true, false] {
        let ev = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)!
        ev.flags = flags
        if let text { ev.keyboardSetUnicodeString(stringLength: text.utf16.count, unicodeString: Array(text.utf16)) }
        ev.postToPid(pid)
        if settle { usleep(30_000) }
    }
}

func windowID(_ pid: pid_t) -> Int? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.first { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }?[kCGWindowNumber as String] as? Int
}

let usage = """
    makoctl <pid> tree [depth] [--menus]   accessibility tree of the process
    makoctl <pid> title                    main window title
    makoctl <pid> value <ax-identifier>    AXValue of the element with that identifier
    makoctl <pid> exists <ax-identifier>   exit 0 if present in the tree
    makoctl <pid> menu <Menu> <Item>       press a menu item via AX
    makoctl <pid> press <name>             AXPress the first control whose title/desc/value is name (web buttons, links)
    makoctl <pid> windows                  one line per window (popups have id="mako.popup")
    makoctl <pid> menu-items <Menu>        list a menu's item titles (checked = active)
    makoctl <pid> key <combo>              e.g. return, escape, cmd+t, cmd+1, cmd+z
    makoctl <pid> type <text>              type text into the focused element
    makoctl <pid> wait-title <substring> [seconds]
    makoctl <pid> time-key <combo> <substring>   ms from key press until the title contains substring
    makoctl <pid> shot <path.png>          screenshot of the window
    """

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2, let pid = pid_t(args[0]) else { fail(usage, 64) }
guard AXIsProcessTrusted() else { fail("accessibility permission missing for this terminal", 2) }
guard NSRunningApplication(processIdentifier: pid) != nil else { fail("pid \(pid) not running", 3) }
let app = AXUIElementCreateApplication(pid)
func mainWindow() -> AXUIElement {
    guard let window = (attr(app, kAXWindowsAttribute) as? [AXUIElement])?.first(where: { str($0, kAXSubroleAttribute) == kAXStandardWindowSubrole })
    else {
        // macOS sometimes degrades AX for this terminal: every app reports itself as its own window.
        // Re-toggling the terminal's Accessibility permission and restarting it fixes that.
        if (attr(app, kAXWindowsAttribute) as? [AXUIElement])?.first.map({ CFEqual($0, app) }) == true {
            let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
            fail(locked
                ? "accessibility degraded: the screen is locked; unlock it and retry"
                : "accessibility degraded system-wide (window == app) with the screen unlocked; re-toggle the terminal in Privacy & Security → Accessibility and restart it", 8)
        }
        fail("no standard window")
    }
    return window
}

// A background app has no key window, so keys and nil-targeted menu actions go nowhere.
func focus() {
    guard let running = NSRunningApplication(processIdentifier: pid), !running.isActive else { return }
    // macOS may refuse a background tool's request while the user works in another app; retry.
    let deadline = Date().addingTimeInterval(4)
    while !running.isActive && Date() < deadline {
        running.activate(options: [.activateAllWindows])
        for _ in 0..<10 where !running.isActive { usleep(50_000) }
    }
    if !running.isActive { fail("could not activate pid \(pid): another app kept focus; ask the user to stop typing during the run", 7) }
    usleep(150_000)
}

if ["menu", "key", "type", "time-key", "press"].contains(args[1]) { focus() }

func postCombo(_ combo: String, settle: Bool = true) {
    let parts = combo.lowercased().split(separator: "+").map(String.init)
    guard let code = keyCodes[parts.last!] else { fail("unknown key \(parts.last!)", 64) }
    var flags: CGEventFlags = []
    if parts.contains("cmd") { flags.insert(.maskCommand) }
    if parts.contains("shift") { flags.insert(.maskShift) }
    if parts.contains("opt") { flags.insert(.maskAlternate) }
    post(pid, key: code, flags: flags, settle: settle)
}

switch args[1] {
case "tree":
    dump(app, 0, args.count > 2 ? Int(args[2]) ?? 12 : 12, menus: args.contains("--menus"))
case "title":
    print(str(mainWindow(), kAXTitleAttribute) ?? "")
case "value", "exists":
    guard args.count > 2 else { fail(usage, 64) }
    guard let e = find(app, id: args[2]) else { fail("no element \(args[2])", 4) }
    if args[1] == "value" { print(str(e, kAXValueAttribute) ?? "") }
case "menu":
    guard args.count > 3 else { fail(usage, 64) }
    AXUIElementPerformAction(menuItem(app, args[2], args[3]), kAXPressAction as CFString)
case "press":
    guard args.count > 2 else { fail(usage, 64) }
    guard let e = find(app, named: args[2]) else { fail("no pressable element named \"\(args[2])\"", 4) }
    AXUIElementPerformAction(e, kAXPressAction as CFString)
case "windows":
    for w in (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] { print(line(w)) }
case "menu-items":
    guard args.count > 2 else { fail(usage, 64) }
    for i in children(submenu(app, args[2])) { if let t = str(i, kAXTitleAttribute) { print(line(i).contains("checked") ? "* \(t)" : "  \(t)") } }
case "key":
    guard args.count > 2 else { fail(usage, 64) }
    postCombo(args[2])
case "time-key":
    guard args.count > 3 else { fail(usage, 64) }
    let start = Date()
    postCombo(args[2], settle: false)
    while Date().timeIntervalSince(start) < 5 {
        if (str(mainWindow(), kAXTitleAttribute) ?? "").contains(args[3]) {
            print(Int(Date().timeIntervalSince(start) * 1000))
            exit(0)
        }
        usleep(5_000)
    }
    fail("title never contained \"\(args[3])\" within 5s", 5)
case "type":
    guard args.count > 2 else { fail(usage, 64) }
    for ch in args[2] { post(pid, key: 0, text: String(ch)) }
case "wait-title":
    guard args.count > 2 else { fail(usage, 64) }
    let deadline = Date().addingTimeInterval(args.count > 3 ? Double(args[3]) ?? 10 : 10)
    while Date() < deadline {
        let t = str(mainWindow(), kAXTitleAttribute) ?? ""
        if t.contains(args[2]) { print(t); exit(0) }
        usleep(50_000)
    }
    fail("title never contained \"\(args[2])\"; last: \(str(mainWindow(), kAXTitleAttribute) ?? "")", 5)
case "shot":
    guard args.count > 2, let wid = windowID(pid) else { fail("no on-screen window", 4) }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-o", "-x", "-l\(wid)", args[2]]
    try! p.run()
    p.waitUntilExit()
    if p.terminationStatus != 0 { fail("screencapture failed (screen recording permission?)", 6) }
    print(args[2])
default:
    fail(usage, 64)
}
