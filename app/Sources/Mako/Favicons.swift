import AppKit
import ImageIO

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
    /// Redirects pass the same http(s) and blocklist checks as the first request.
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        return URLSession(configuration: config, delegate: RedirectGuard(), delegateQueue: nil)
    }()
    private static let maxBytes = 1_000_000

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

    /// http(s) and not blocked: fetching a blocked host's icon would be a visit by another name.
    nonisolated static func allowed(_ url: URL?) -> Bool {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host() else { return false }
        return Core.blockReason(host: host) == nil
    }

    private static func key(_ url: URL) -> String? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host()?.lowercased(),
              Core.blockReason(host: host) == nil else { return nil }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    /// Decodes only PNG, ICO, GIF and JPEG, recognised by their first bytes and decoded as that
    /// type, so a hostile file never reaches a decoder it did not announce (SVG included).
    nonisolated static func decode(_ data: Data) -> NSImage? {
        let formats: [([UInt8], String)] = [
            ([0x89, 0x50, 0x4E, 0x47], "public.png"), ([0x00, 0x00, 0x01, 0x00], "com.microsoft.ico"),
            ([0x47, 0x49, 0x46, 0x38], "com.compuserve.gif"), ([0xFF, 0xD8, 0xFF], "public.jpeg"),
        ]
        guard let type = formats.first(where: { data.starts(with: $0.0) })?.1,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceTypeIdentifierHint: type] as CFDictionary),
              CGImageSourceGetType(source) as String? == type, CGImageSourceGetCount(source) > 0 else { return nil }
        // An .ico holds several sizes: take the one nearest 32 px.
        let width = { (i: Int) in (CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any])?[kCGImagePropertyPixelWidth] as? Int ?? 0 }
        let best = (0..<CGImageSourceGetCount(source)).min { abs(width($0) - 32) < abs(width($1) - 32) } ?? 0
        guard let image = CGImageSourceCreateImageAtIndex(source, best, nil), image.width > 0 else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }

    /// `fallback` is set for a declared icon: the page's /favicon.ico, tried if it fails.
    private func fetch(_ url: URL, for host: String, else fallback: URL? = nil) {
        guard Self.allowed(url) else { return }
        fetching.insert(host)
        Task { [session] in
            let image: NSImage? = await {
                guard let (bytes, response) = try? await session.bytes(from: url),
                      (response as? HTTPURLResponse)?.statusCode == 200, Self.allowed(response.url),
                      response.expectedContentLength <= Self.maxBytes else { return nil }
                var data = Data()
                do {
                    for try await byte in bytes {
                        data.append(byte)
                        if data.count > Self.maxBytes { return nil }
                    }
                } catch { return nil }
                return Self.decode(data)
            }()
            fetching.remove(host)
            if let image {
                icons[host] = image
                if fallback != nil { declared.insert(host) }
                log.info("favicon \(host, privacy: .public) from \(url.absoluteString, privacy: .public)")
                onChange()
            } else if let fallback {
                if icons[host] == nil, !failed.contains(host) { fetch(fallback, for: host) }
            } else {
                failed.insert(host)
                log.info("favicon \(host, privacy: .public) none at \(url.absoluteString, privacy: .public)")
            }
        }
    }
}

/// Refuses a redirect to a non-http(s) address or a blocked host.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        Favicons.allowed(request.url) ? request : nil
    }
}
