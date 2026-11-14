import AppKit
import MakoCore

/// One row under the address bar, as the core ranked it.
struct Suggestion {
    /// Set for a page already open in a trail: its id and its trail's colour slot.
    let open: (id: UInt64, color: Int)?
    let title: String
    let url: String

    init?(_ json: [String: Any]) {
        guard let url = json["url"] as? String, let kind = json["kind"] as? String else { return nil }
        self.url = url
        let title = json["title"] as? String ?? ""
        self.title = title.isEmpty ? url : title
        if kind == "open_page" {
            guard let id = json["id"] as? UInt64 else { return nil }
            open = (id, json["color"] as? Int ?? 0)
        } else {
            open = nil
        }
    }
}

/// The pages visited. The core owns every rule and the entries; this holds its handle, reads
/// the clock, and writes the result to disk. Nothing here leaves the Mac.
@MainActor
final class HistoryStore {
    /// Beside the config, so MAKO_CONFIG runs get their own history.
    static var fileURL: URL { Core.configURL.deletingLastPathComponent().appending(path: "history.json") }

    /// Only this store touches the handle, on the main actor; deinit frees it.
    nonisolated(unsafe) private let handle: OpaquePointer

    init() {
        let saved = try? String(contentsOf: Self.fileURL, encoding: .utf8)
        if let handle = mako_history_load(saved) {
            self.handle = handle
        } else {
            // Keep the unreadable file for inspection and start empty rather than lose it silently.
            log.error("history.json rejected")
            try? FileManager.default.moveItem(at: Self.fileURL, to: Self.fileURL.appendingPathExtension("bad"))
            handle = mako_history_load(nil)!
        }
    }

    deinit { mako_history_free(handle) }

    /// A page finished loading. The core decides whether it counts (web pages only, never a
    /// blocked host, nothing with `remember_history = false`).
    func visited(_ url: String, title: String, at date: Date = .now) {
        let (weekday, minute) = Core.weekdayAndMinute(date)
        if mako_history_visit(handle, Core.config, url, title, UInt64(max(0, date.timeIntervalSince1970)), weekday, minute) { save() }
    }

    func retitled(_ url: String, title: String) {
        if mako_history_retitle(handle, url, title) { save() }
    }

    func clear() {
        if mako_history_clear(handle) { save() }
    }

    /// Rows for what is typed in the address bar; `trails` is the core's trails state.
    func suggestions(for query: String, trails: String, at date: Date = .now) -> [Suggestion] {
        guard let reply = Core.take(mako_suggest(handle, Core.config, trails, query, UInt64(max(0, date.timeIntervalSince1970)))),
              let rows = try? JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [[String: Any]] else { return [] }
        return rows.compactMap(Suggestion.init)
    }

    // shortcut: rewrites the whole file on every visit, under a megabyte at the 5,000-entry
    // cap; switch to an append log if saves show up in profiles.
    private func save() {
        guard let text = Core.take(mako_history_save(handle)) else { return }
        do { try text.write(to: Self.fileURL, atomically: true, encoding: .utf8) }
        catch { log.error("could not save history: \(error.localizedDescription, privacy: .public)") }
    }
}
