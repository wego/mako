import AppKit

/// Site icons for sidebar rows, by host. A page's own declared icon wins; any host without
/// one gets /favicon.ico, so rows of pages that never loaded have icons too. A host that
/// failed is not asked again this session.
@MainActor
final class Favicons {
    var onChange: () -> Void = {}

    private var icons: [String: NSImage] = [:]
    private var failed: Set<String> = []
    private var fetching: Set<String> = []
    /// Hosts whose icon came from a page's declaration; /favicon.ico never replaces those.
    private var declared: Set<String> = []

    /// Sends no cookies and keeps none: an icon request must not identify the person.
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()

    /// Picks the page's best declared icon: the `rel~=icon` link sized nearest 32 px,
    /// else an apple-touch-icon. Returns its absolute URL, or null.
    static let script = """
        (() => {
          const size = l => Math.max(0, ...(l.sizes ? [...l.sizes].map(s => parseInt(s) || 0) : [0]));
          const icons = [...document.querySelectorAll('link[rel~="icon" i]')].filter(l => l.href);
          icons.sort((a, b) => Math.abs((size(a) || 32) - 32) - Math.abs((size(b) || 32) - 32));
          const touch = document.querySelector('link[rel~="apple-touch-icon" i]');
          return (icons[0] || touch || {}).href || null;
        })()
        """

    /// The icon for a page's address, starting a /favicon.ico fetch the first time a host is seen.
    func icon(for address: String) -> NSImage? {
        guard let url = URL(string: address), let host = Self.key(url) else { return nil }
        if let icon = icons[host] { return icon }
        if !failed.contains(host), !fetching.contains(host), let fallback = URL(string: "/favicon.ico", relativeTo: url) {
            fetch(fallback.absoluteURL, for: host)
        }
        return nil
    }

    /// A loaded page declared `icon` (from `script`). It replaces a /favicon.ico icon.
    func pageDeclared(_ icon: URL, on page: URL) {
        guard let host = Self.key(page), !declared.contains(host), !fetching.contains(host) else { return }
        fetch(icon, for: host, else: URL(string: "/favicon.ico", relativeTo: page)?.absoluteURL)
    }

    /// http(s) only, and never a blocked host: fetching it would be a visit by another name.
    private static func key(_ url: URL) -> String? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host()?.lowercased(),
              Core.blockReason(host: host) == nil else { return nil }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    /// `fallback` is set for a declared icon: the page's /favicon.ico, tried if it fails.
    private func fetch(_ url: URL, for host: String, else fallback: URL? = nil) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host().map({ Core.blockReason(host: $0) == nil }) ?? false else { return }
        fetching.insert(host)
        Task { [session] in
            let image: NSImage? = await {
                guard let (data, response) = try? await session.data(from: url),
                      (response as? HTTPURLResponse)?.statusCode == 200, data.count < 1_000_000,
                      let image = NSImage(data: data), image.isValid, image.size.width > 0 else { return nil }
                return image
            }()
            fetching.remove(host)
            if let image {
                icons[host] = image
                if fallback != nil { declared.insert(host) }
                log.info("favicon \(host, privacy: .public) from \(url.absoluteString, privacy: .public)")
                onChange()
            } else if let fallback {
                if icons[host] == nil { fetch(fallback, for: host) }
            } else {
                failed.insert(host)
                log.info("favicon \(host, privacy: .public) none at \(url.absoluteString, privacy: .public)")
            }
        }
    }
}
