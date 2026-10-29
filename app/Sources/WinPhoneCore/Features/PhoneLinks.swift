import Foundation

// Links across the two devices (`protocol/specs/continuity.md`).
//
// From the phone, a link reaches this computer two ways: copied there, it arrives with the
// clipboard; and apps that tell Link to Windows what the user is doing ("continue on PC")
// have that pushed as an app context, which may carry a web link.
//
// Toward the phone there is no "open this" in the protocol. A link is sent as a small page
// that the phone offers to open like any file it received.

/// Something the user was doing on the phone that could be carried on elsewhere.
public struct PhoneAppContext: Equatable, Sendable {
    /// What the phone did with it: made or changed it, or took it away.
    public enum Action: Equatable, Sendable { case update, delete }

    public var id: Int64
    /// The package name of the app it belongs to.
    public var appId: String
    /// "BrowserHistory" for a page open in a browser, "ResumeActivity" for something in an app.
    public var type: String
    public var title: String
    public var webLink: String
    /// How the phone would reopen it; an app's own scheme more often than a web address.
    public var intentUri: String
    public var action: Action

    public init(id: Int64, appId: String, type: String, title: String = "", webLink: String = "", intentUri: String = "", action: Action = .update) {
        self.id = id
        self.appId = appId
        self.type = type
        self.title = title
        self.webLink = webLink
        self.intentUri = intentUri
        self.action = action
    }

    /// Where a computer can go on from here: the web link, or the reopening address when that
    /// is a web address too.
    public var url: URL? {
        for text in [webLink, intentUri] {
            if let url = PhoneLinks.webURL(text) { return url }
        }
        return nil
    }

    /// The contexts in a `continuityAppContext` push: parallel arrays, one entry per context.
    public static func contexts(in values: ValueSet) -> [PhoneAppContext] {
        guard let ids = values.int64s("appContextIds") else { return [] }
        let apps = values.strings("appContextAppIds") ?? [], types = values.strings("appContextTypes") ?? []
        let titles = values.strings("appContextTitles") ?? [], links = values.strings("appContextWebLinks") ?? []
        let intents = values.strings("appContextIntentUris") ?? [], actions = values.int32s("appContextActions") ?? []
        func at(_ list: [String], _ index: Int) -> String { index < list.count ? list[index] : "" }
        return ids.enumerated().map { index, id in
            // 2 is "deleted" in every content sync of this protocol; anything else is news.
            PhoneAppContext(id: id, appId: at(apps, index), type: at(types, index), title: at(titles, index), webLink: at(links, index),
                            intentUri: at(intents, index), action: index < actions.count && actions[index] == 2 ? .delete : .update)
        }
    }
}

public enum PhoneLinks {
    /// A web address from text that is one, and nothing else.
    public static func webURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 4096, !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// The link in something copied on the phone, when a link is what was copied: the text is
    /// a web address, or a short text with exactly one in it (a place's name above its map
    /// link, a title before an article's address). A longer text that happens to mention a
    /// link is just text.
    public static func link(inCopied text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = webURL(trimmed) { return url }
        if let place = mapURL(forGeo: trimmed) { return place }
        guard trimmed.count <= 600 else { return nil }
        let words = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        let links = words.compactMap(webURL)
        guard links.count == 1 else { return nil }
        // What stands around the link must be short enough to be its caption.
        let rest = words.filter { webURL($0) == nil }.joined(separator: " ")
        return rest.count <= 200 ? links[0] : nil
    }

    /// A phone's "geo:" address for a place, as a map page a computer opens.
    public static func mapURL(forGeo text: String) -> URL? {
        guard text.lowercased().hasPrefix("geo:"), !text.contains(where: \.isWhitespace) else { return nil }
        let body = text.dropFirst(4)
        let coordinates = body.split(separator: "?").first.map(String.init) ?? ""
        let parts = coordinates.split(separator: ";").first?.split(separator: ",").compactMap { Double($0) } ?? []
        var components = URLComponents(string: "https://maps.apple.com/")
        if parts.count >= 2, (-90...90).contains(parts[0]), (-180...180).contains(parts[1]), !(parts[0] == 0 && parts[1] == 0) {
            components?.queryItems = [URLQueryItem(name: "ll", value: "\(parts[0]),\(parts[1])")]
        } else if let query = URLComponents(string: "geo://x?" + (body.split(separator: "?").dropFirst().first.map(String.init) ?? ""))?.queryItems?.first(where: { $0.name == "q" })?.value, !query.isEmpty {
            components?.queryItems = [URLQueryItem(name: "q", value: query)]
        } else {
            return nil
        }
        return components?.url
    }

    /// A name for the file a link travels in: the site, safe for any file system.
    public static func fileName(for url: URL) -> String {
        let host = (url.host ?? "link").replacingOccurrences(of: "www.", with: "")
        let safe = String(host.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" }.prefix(60))
        return "Link to \(safe.isEmpty ? "page" : safe).html"
    }

    /// The page a link travels in. Opened on the phone it goes straight to the address, and
    /// where a viewer does not follow that by itself, it shows the address large enough to tap.
    public static func page(for url: URL) -> Data {
        func escaped(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let address = escaped(url.absoluteString)
        let script = (try? JSONSerialization.data(withJSONObject: [url.absoluteString])).map { String(decoding: $0, as: UTF8.self) } ?? "[\"\"]"
        // The address inside a script must not be able to end the script.
        let safeScript = script.replacingOccurrences(of: "</", with: "<\\/")
        return Data("""
        <!doctype html>
        <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="refresh" content="0; url=\(address)">
        <title>\(escaped(url.host ?? "Link"))</title>
        <style>body{font:18px -apple-system,Roboto,sans-serif;margin:15vh 8vw;text-align:center}a{display:inline-block;margin-top:1em;padding:.8em 1.4em;border-radius:1.4em;background:#0b57d0;color:#fff;text-decoration:none;word-break:break-all}</style>
        </head><body><p>Sent from your Mac</p><a href="\(address)">Open \(escaped(url.host ?? "link"))</a>
        <script>location.replace(\(safeScript)[0]);</script></body></html>
        """.utf8)
    }
}
