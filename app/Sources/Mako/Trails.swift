import Foundation

/// One visible sidebar row, as the core computed it.
struct TrailRow {
    let id: UInt64
    let depth: Int
    let label: String
    let url: String
    let title: String
    let active: Bool
    let collapsed: Bool
    let hasChildren: Bool
    /// The trail's colour slot; the shell maps it onto its palette.
    let color: Int

    init?(_ json: [String: Any]) {
        guard let id = json["id"] as? UInt64, let depth = json["depth"] as? Int,
              let label = json["label"] as? String, let url = json["url"] as? String else { return nil }
        self.id = id
        self.depth = depth
        self.label = label
        self.url = url
        title = json["title"] as? String ?? ""
        active = json["active"] as? Bool ?? false
        collapsed = json["collapsed"] as? Bool ?? false
        hasChildren = json["has_children"] as? Bool ?? false
        color = json["color"] as? Int ?? 0
    }
}

/// The page tree. The Rust core owns every rule; this holds the state it returns, asks it
/// for each change, and writes the result to disk so trails and Undo Close survive a restart.
@MainActor
final class TrailStore {
    private(set) var rows: [TrailRow] = []
    /// Every page id, including pages hidden inside collapsed ones.
    private(set) var pages: Set<UInt64> = []
    /// The colour slot the next new trail would get.
    private(set) var nextColor = 0
    /// The core's whole state, as it returned it.
    private(set) var state = ""

    /// Beside the config, so MAKO_CONFIG runs get their own trails.
    static var fileURL: URL { Core.configURL.deletingLastPathComponent().appending(path: "trails.json") }
    private static var legacySessionURL: URL { Core.configURL.deletingLastPathComponent().appending(path: "session.json") }

    var active: TrailRow? { rows.first(where: \.active) }

    init() {
        let saved = Core.restoreSession ? try? String(contentsOf: Self.fileURL, encoding: .utf8) : nil
        if let error = take(Core.trails(state: saved, action: nil)) {
            // Keep the unreadable file for inspection and start empty rather than lose it silently.
            log.error("trails.json rejected: \(error, privacy: .public)")
            try? FileManager.default.moveItem(at: Self.fileURL, to: Self.fileURL.appendingPathExtension("bad"))
            _ = take(Core.trails(state: nil, action: nil))
        }
        if saved == nil, Core.restoreSession { migrateSession() }
    }

    /// Asks the core for one change. Returns its error message, or nil when applied and saved.
    @discardableResult
    func apply(_ type: String, _ fields: [String: Any] = [:]) -> String? {
        var action = fields
        action["type"] = type
        guard let data = try? JSONSerialization.data(withJSONObject: action) else { return "bad action" }
        let error = take(Core.trails(state: state, action: String(decoding: data, as: UTF8.self)))
        if error == nil { save() }
        return error
    }

    private func take(_ reply: [String: Any]) -> String? {
        guard let stateJSON = reply["state"], let data = try? JSONSerialization.data(withJSONObject: stateJSON) else {
            return reply["error"] as? String ?? "malformed reply"
        }
        state = String(decoding: data, as: UTF8.self)
        rows = (reply["rows"] as? [[String: Any]] ?? []).compactMap(TrailRow.init)
        pages = Set(reply["pages"] as? [UInt64] ?? [])
        nextColor = reply["next_color"] as? Int ?? 0
        return nil
    }

    // shortcut: rewrites the whole file on every change, fine up to a few thousand pages;
    // switch to an append log if saves show up in profiles.
    private func save() {
        guard Core.restoreSession else { return }
        do { try state.write(to: Self.fileURL, atomically: true, encoding: .utf8) }
        catch { log.error("could not save trails: \(error.localizedDescription, privacy: .public)") }
    }

    /// First launch after the tabs era: each saved tab becomes a trail, the rest pages of the last one.
    private func migrateSession() {
        struct Session: Decodable { let tabs: [URL]; let active: Int }
        guard let data = try? Data(contentsOf: Self.legacySessionURL),
              let session = try? JSONDecoder().decode(Session.self, from: data) else { return }
        var ids: [UInt64] = []
        for url in session.tabs {
            if apply("open_trail", ["url": url.absoluteString]) != nil, let last = rows.last(where: { $0.depth == 0 }) {
                apply("open_child", ["parent": last.id, "url": url.absoluteString])
            }
            if let id = active?.id { ids.append(id) }
        }
        if ids.indices.contains(session.active) { apply("select", ["id": ids[session.active]]) }
    }
}
