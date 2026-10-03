import Foundation
import MakoCore

/// Swift face of the Rust core. Reads the config file on each call so edits apply live.
enum Core {
    /// MAKO_CONFIG lets verification runs use a disposable config.
    static let configURL = ProcessInfo.processInfo.environment["MAKO_CONFIG"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/mako/config")

    static let template = """
        # Mako config – edits apply on the next navigation.
        max_tabs = 3
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
    static var maxTabs: Int { Int(mako_max_tabs(config)) }
    static func resolve(_ input: String) -> URL? { take(mako_resolve(config, input)).flatMap(URL.init(string:)) }

    static func blockReason(host: String, at date: Date = .now) -> String? {
        let c = Calendar.current.dateComponents([.weekday, .hour, .minute], from: date)
        let weekday = UInt8((c.weekday! + 5) % 7) // Calendar: Sunday = 1; core: Monday = 0
        return take(mako_blocked(config, host, weekday, UInt16(c.hour! * 60 + c.minute!)))
    }
}
