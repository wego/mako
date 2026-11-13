import Foundation
import MakoCore

/// Swift face of the Rust core. Reads the config file on each call so edits apply live.
enum Core {
    /// MAKO_CONFIG lets verification runs use a disposable config.
    static let configURL = ProcessInfo.processInfo.environment["MAKO_CONFIG"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/mako/config")

    static let template = """
        # Mako config – edits apply on the next navigation.
        max_trails = 3
        # restore_session = false   # start empty instead of reopening your trails
        # search = https://duckduckgo.com/?q=%s

        # block <domain> [HH:MM-HH:MM] [mon-fri | sat,sun | weekdays | weekends | daily]
        # block x.com
        # block youtube.com 09:00-18:00 weekdays

        """

    static func ensureConfig() {
        guard !FileManager.default.fileExists(atPath: configURL.path) else { return }
        try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? template.write(to: configURL, atomically: true, encoding: .utf8)
    }

    private static var config: String { (try? String(contentsOf: configURL, encoding: .utf8)) ?? "" }

    private static func take(_ p: UnsafeMutablePointer<CChar>?) -> String? {
        guard let p else { return nil }
        defer { mako_free(p) }
        return String(cString: p)
    }

    static var configError: String? { take(mako_config_error(config)) }
    static var restoreSession: Bool { mako_restore_session(config) }
    static var maxTrails: Int { Int(mako_max_trails(config)) }
    static let trailLimit = Int(mako_trail_limit())

    /// Rewrites one `key = value` line of the config file, keeping the rest as the user wrote it.
    static func set(_ key: String, _ value: String) {
        guard let text = take(mako_set_setting(config, key, value)) else { return }
        try? text.write(to: configURL, atomically: true, encoding: .utf8)
    }

    /// One trails call into the core. The reply is JSON: new state, rows and page ids, or an error.
    static func trails(state: String?, action: String?) -> [String: Any] {
        let reply = action.map { take(mako_trails_apply(config, state, $0)) } ?? take(mako_trails_load(state))
        return reply.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? ["error": "no reply from core"]
    }

    static func resolve(_ input: String) -> URL? { take(mako_resolve(config, input)).flatMap(URL.init(string:)) }

    static func blockReason(host: String, at date: Date = .now) -> String? {
        let c = Calendar.current.dateComponents([.weekday, .hour, .minute], from: date)
        let weekday = UInt8((c.weekday! + 5) % 7) // Calendar: Sunday = 1; core: Monday = 0
        return take(mako_blocked(config, host, weekday, UInt16(c.hour! * 60 + c.minute!)))
    }
}
