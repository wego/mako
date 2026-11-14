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
                   ("desc", kAXDescriptionAttribute), ("value", kAXValueAttribute), ("placeholder", "AXPlaceholderValue")] {
        if let s = str(e, a) { parts.append("\(k)=\"\(s.prefix(80).replacingOccurrences(of: "\n", with: "⏎"))\"") }
    }
    if let on = attr(e, "AXMenuItemMarkChar") as? String, !on.isEmpty { parts.append("checked") }
    if let key = attr(e, "AXMenuItemCmdChar") as? String, !key.isEmpty { parts.append("cmd=\"\(key)\"") }
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
    "return": 36, "escape": 53, "tab": 48, "[": 33, "]": 30,
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
    "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
    "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "=": 24, "-": 27, "0": 29, ",": 43, ".": 47,
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

/// The main window: the largest of the process's windows, so an open Settings window or
/// sign-in popup in front of it is not what `shot` captures.
func windowID(_ pid: pid_t) -> Int? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    func area(_ w: [String: Any]) -> Double {
        let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
        return (b["Width"] ?? 0) * (b["Height"] ?? 0)
    }
    return list.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
        .max { area($0) < area($1) }?[kCGWindowNumber as String] as? Int
}

let usage = """
    makoctl <pid> tree [depth] [--menus]   accessibility tree of the process
    makoctl <pid> title                    main window title
    makoctl <pid> value <ax-identifier>    AXValue of the element with that identifier
    makoctl <pid> exists <ax-identifier>   exit 0 if present in the tree
    makoctl <pid> frame <ax-identifier>    "x y width height" of the element, screen points from the top-left
    makoctl <pid> menu <Menu> <Item>       press a menu item via AX
    makoctl <pid> press <name>             AXPress the first control whose title/desc/value is name (web buttons, links)
    makoctl <pid> text                     full visible text of the active page, one line per text run
    makoctl <pid> pointer-center           move the mouse pointer over the middle of the page (perf runs)
    makoctl <pid> press-id <ax-identifier>   AXPress the element with that identifier (sidebar rows)
    makoctl <pid> set <ax-identifier> <text> set an element's value (the omnibox field)
    makoctl <pid> confirm <ax-identifier>    AXConfirm (Enter) on a text field
    makoctl <pid> windows                  one line per window (popups have id="mako.popup")
    makoctl <pid> menu-items <Menu>        list a menu's item titles (checked = active)
    makoctl <pid> key <combo>              e.g. return, escape, cmd+t, cmd+1, cmd+f, ctrl+tab
    makoctl <pid> type <text>              type text into the focused element
    makoctl <pid> wait-title <substring> [seconds]
    makoctl <pid> time-key <combo> <substring>   ms from key press until the title contains substring
    makoctl <pid> shot <path.png>          screenshot of the window
    makoctl <pid> click-id <ax-identifier> [fx fy]   real mouse click at a point of the element (fractions of its frame, default 0.5 0.5)
    makoctl <pid> middle-click-id <ax-identifier> [fx fy]   real middle-button click there (a sidebar row)
    makoctl <pid> middle-click <x> <y>     real middle-button click at x,y points from the page's top-left (CSS px at 100% zoom)
    makoctl <pid> window-frame             "x y width height" of the main window, screen points from the top-left
    makoctl <pid> hover <x> <y>            move the real pointer to x,y points from the window's top-left
    makoctl <pid> drag <x> <y> <dx> <dy>   real left-button drag from x,y (window points) by dx,dy
    makoctl <pid> double-click <x> <y>     real left double-click at x,y (window points)
    """

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2, let pid = pid_t(args[0]) else { fail(usage, 64) }
// A screenshot needs only Screen Recording, so it works where Accessibility is not granted.
guard AXIsProcessTrusted() || args[1] == "shot" else { fail("accessibility permission missing for this terminal", 2) }
guard NSRunningApplication(processIdentifier: pid) != nil else { fail("pid \(pid) not running", 3) }
let app = AXUIElementCreateApplication(pid)

// While the screen is locked, or when this terminal's grant goes stale, every app reports
// itself as its own window, so walking the tree from the app never ends and overflows the
// stack. Every command that reads the tree checks first and exits 8 instead.
func failIfDegraded() {
    guard (attr(app, kAXWindowsAttribute) as? [AXUIElement])?.first.map({ CFEqual($0, app) }) == true else { return }
    let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    fail(locked
        ? "accessibility degraded: the screen is locked; unlock it and retry"
        : "accessibility degraded system-wide (window == app) with the screen unlocked; re-toggle the terminal in Privacy & Security → Accessibility and restart it", 8)
}
if args[1] != "shot" { failIfDegraded() }

/// The largest standard window, as `shot` picks: Settings is a standard window too, and
/// while it is open it can come first in AXWindows.
func mainWindow() -> AXUIElement {
    func area(_ w: AXUIElement) -> Double {
        var size = CGSize.zero
        if let v = attr(w, kAXSizeAttribute) { AXValueGetValue(v as! AXValue, .cgSize, &size) }
        return size.width * size.height
    }
    guard let window = (attr(app, kAXWindowsAttribute) as? [AXUIElement])?
        .filter({ str($0, kAXSubroleAttribute) == kAXStandardWindowSubrole }).max(by: { area($0) < area($1) })
    else {
        // The screen can lock while wait-title or time-key polls.
        failIfDegraded()
        fail("no standard window")
    }
    return window
}

// A background app has no key window, so keys and nil-targeted menu actions go nowhere.
func focus() {
    // MAKO_BACKGROUND=1: never take focus. Only AX actions work then (menu, press, set, confirm).
    if ProcessInfo.processInfo.environment["MAKO_BACKGROUND"] == "1" {
        if ["key", "type", "time-key", "click-id", "middle-click-id", "middle-click", "hover", "drag", "double-click"].contains(args[1]) { fail("\(args[1]) needs focus; not available with MAKO_BACKGROUND=1", 9) }
        return
    }
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

if ["menu", "key", "type", "time-key", "press", "click-id", "middle-click-id", "middle-click", "hover", "drag", "double-click"].contains(args[1]) { focus() }

func frame(_ id: String) -> CGRect {
    guard let e = find(app, id: id), let pos = attr(e, kAXPositionAttribute), let size = attr(e, kAXSizeAttribute) else { fail("no element \(id)", 4) }
    var p = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(pos as! AXValue, .cgPoint, &p)
    AXValueGetValue(size as! AXValue, .cgSize, &sz)
    return CGRect(origin: p, size: sz)
}

func windowFrame() -> CGRect {
    guard let pos = attr(mainWindow(), kAXPositionAttribute), let size = attr(mainWindow(), kAXSizeAttribute) else { fail("no window frame", 4) }
    var p = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(pos as! AXValue, .cgPoint, &p)
    AXValueGetValue(size as! AXValue, .cgSize, &sz)
    return CGRect(origin: p, size: sz)
}

/// x,y arguments from index i, as a screen point from the window's top-left.
func windowPoint(_ i: Int) -> CGPoint {
    guard args.count > i + 1, let x = Double(args[i]), let y = Double(args[i + 1]) else { fail(usage, 64) }
    let w = windowFrame()
    return CGPoint(x: w.minX + x, y: w.minY + y)
}

func mouse(_ type: CGEventType, _ at: CGPoint, clicks: Int64 = 1) {
    let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: at, mouseButton: .left)!
    e.setIntegerValueField(.mouseEventClickState, value: clicks)
    e.post(tap: .cghidEventTap)
}

/// A real HID click; moves the user's pointer.
func hidClick(at: CGPoint, button: CGMouseButton) {
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: at, mouseButton: .left)!.post(tap: .cghidEventTap)
    usleep(100_000)
    let types: [CGEventType] = button == .left ? [.leftMouseDown, .leftMouseUp] : [.otherMouseDown, .otherMouseUp]
    for type in types {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: at, mouseButton: button)!.post(tap: .cghidEventTap)
        usleep(60_000)
    }
}

func postCombo(_ combo: String, settle: Bool = true) {
    let parts = combo.lowercased().split(separator: "+").map(String.init)
    guard let code = keyCodes[parts.last!] else { fail("unknown key \(parts.last!)", 64) }
    var flags: CGEventFlags = []
    if parts.contains("cmd") { flags.insert(.maskCommand) }
    if parts.contains("shift") { flags.insert(.maskShift) }
    if parts.contains("opt") { flags.insert(.maskAlternate) }
    if parts.contains("ctrl") { flags.insert(.maskControl) }
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
    if args[1] == "value" { print(str(e, kAXValueAttribute) ?? (attr(e, kAXValueAttribute) as? NSNumber)?.stringValue ?? "") }
case "frame":
    guard args.count > 2 else { fail(usage, 64) }
    let f = frame(args[2])
    print(Int(f.minX), Int(f.minY), Int(f.width), Int(f.height))
case "menu":
    guard args.count > 3 else { fail(usage, 64) }
    AXUIElementPerformAction(menuItem(app, args[2], args[3]), kAXPressAction as CFString)
case "press":
    guard args.count > 2 else { fail(usage, 64) }
    guard let e = find(app, named: args[2]) else { fail("no pressable element named \"\(args[2])\"", 4) }
    AXUIElementPerformAction(e, kAXPressAction as CFString)
case "text":
    func webArea(_ e: AXUIElement) -> AXUIElement? {
        if str(e, kAXRoleAttribute) == "AXWebArea" { return e }
        for c in children(e) { if let f = webArea(c) { return f } }
        return nil
    }
    func collect(_ e: AXUIElement) {
        if str(e, kAXRoleAttribute) == kAXStaticTextRole, let v = str(e, kAXValueAttribute) { print(v) }
        children(e).forEach(collect)
    }
    guard let area = webArea(mainWindow()) else { fail("no page content", 4) }
    collect(area)
case "pointer-center":
    // Cursor work depends on where the pointer is; perf runs park it over the page.
    let w = windowFrame()
    CGWarpMouseCursorPosition(CGPoint(x: w.midX, y: w.minY + w.height * 0.6))
case "press-id", "set", "confirm":
    guard args.count > 2 else { fail(usage, 64) }
    guard let e = find(app, id: args[2]) else { fail("no element \(args[2])", 4) }
    let result: AXError
    switch args[1] {
    case "set":
        guard args.count > 3 else { fail(usage, 64) }
        result = AXUIElementSetAttributeValue(e, kAXValueAttribute as CFString, args[3] as CFString)
    case "confirm": result = AXUIElementPerformAction(e, kAXConfirmAction as CFString)
    default: result = AXUIElementPerformAction(e, kAXPressAction as CFString)
    }
    if result != .success { fail("\(args[1]) \(args[2]) failed: AXError \(result.rawValue)", 4) }
case "click-id", "middle-click-id":
    // Stepper arrows: fy 0.25 is up, 0.75 is down (AX y grows downward).
    guard args.count > 2 else { fail(usage, 64) }
    let f = frame(args[2])
    let fx = args.count > 3 ? Double(args[3]) ?? 0.5 : 0.5, fy = args.count > 4 ? Double(args[4]) ?? 0.5 : 0.5
    hidClick(at: CGPoint(x: f.minX + f.width * fx, y: f.minY + f.height * fy), button: args[1] == "click-id" ? .left : .center)
case "middle-click":
    guard args.count > 3, let x = Double(args[2]), let y = Double(args[3]) else { fail(usage, 64) }
    let f = frame("mako.page")
    hidClick(at: CGPoint(x: f.minX + x, y: f.minY + y), button: .center)
case "window-frame":
    let f = windowFrame()
    print(Int(f.minX), Int(f.minY), Int(f.width), Int(f.height))
case "hover":
    mouse(.mouseMoved, windowPoint(2))
case "drag":
    let from = windowPoint(2)
    guard args.count > 5, let dx = Double(args[4]), let dy = Double(args[5]) else { fail(usage, 64) }
    mouse(.mouseMoved, from); usleep(100_000)
    mouse(.leftMouseDown, from); usleep(100_000)
    for step in 1...10 {
        mouse(.leftMouseDragged, CGPoint(x: from.x + dx * Double(step) / 10, y: from.y + dy * Double(step) / 10))
        usleep(30_000)
    }
    mouse(.leftMouseUp, CGPoint(x: from.x + dx, y: from.y + dy))
case "double-click":
    let at = windowPoint(2)
    mouse(.mouseMoved, at); usleep(100_000)
    for clicks in [Int64(1), 2] {
        mouse(.leftMouseDown, at, clicks: clicks); usleep(40_000)
        mouse(.leftMouseUp, at, clicks: clicks); usleep(40_000)
    }
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
