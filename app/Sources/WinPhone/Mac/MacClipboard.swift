import AppKit
import WinPhoneCore

/// The system pasteboard as the sync engine's local clipboard.
final class MacClipboard: LocalClipboard, @unchecked Sendable {
    private let pasteboard: NSPasteboard
    private let lock = NSLock()
    /// Change count after our own last write, so the watcher can tell it apart from a user copy.
    private var ownChangeCount = -1

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int { pasteboard.changeCount }

    /// Whether the current content was put there by `write`.
    var lastChangeWasOurs: Bool {
        lock.lock(); defer { lock.unlock() }
        return pasteboard.changeCount == ownChangeCount
    }

    func read() async -> ClipboardContent? {
        // Skip content other apps marked as transient or concealed, such as password managers do.
        let types = pasteboard.types ?? []
        if types.contains(where: { $0.rawValue == "org.nspasteboard.ConcealedType" || $0.rawValue == "org.nspasteboard.TransientType" }) {
            return nil
        }
        // The phone takes images up to 1 MiB, so larger ones are re-encoded or scaled to fit.
        if let png = pasteboard.data(forType: .png) {
            if png.count <= MacClipboard.imageByteLimit { return .image(png) }
            if let bitmap = NSBitmapImageRep(data: png), let fitted = MacClipboard.fit(bitmap) { return .image(fitted) }
        }
        if let tiff = pasteboard.data(forType: .tiff), let bitmap = NSBitmapImageRep(data: tiff), let fitted = MacClipboard.fit(bitmap) {
            return .image(fitted)
        }
        let html = pasteboard.string(forType: .html), text = pasteboard.string(forType: .string)
        // HTML that macOS made from rich text (Preview, TextEdit, Pages) carries nothing the
        // phone can use, and pasted into a plain field it brought its style sheet along: a bank
        // account number copied from a PDF invoice arrived with code around it (2026-10-15).
        // Then the plain text goes, exactly as selected.
        // Which kinds were there, for the log: never the content.
        diag("clipboard", "copied here: html \(html.map { MacClipboard.isMadeFromRichText($0) ? "made from rich text" : "of its own" } ?? "none"), plain text \(text?.isEmpty == false)")
        if let html, !MacClipboard.isMadeFromRichText(html), let cleaned = MacClipboard.cleanedHTML(html) { return .html(cleaned) }
        if let text, !text.isEmpty { return .text(text) }
        if let html, let cleaned = MacClipboard.cleanedHTML(html) { return .html(cleaned) }
        return nil
    }

    /// Just under the phone's limit of 1 MiB.
    static let imageByteLimit = 1_000_000

    /// Encodes an image within the size limit: PNG when it fits, otherwise JPEG at falling
    /// quality, otherwise a smaller copy. Returns nil only if nothing fits.
    static func fit(_ bitmap: NSBitmapImageRep, limit: Int = MacClipboard.imageByteLimit) -> Data? {
        if let png = bitmap.representation(using: .png, properties: [:]), png.count <= limit { return png }
        var current = bitmap
        for _ in 0..<8 {
            for quality in [0.9, 0.75, 0.6] {
                if let jpeg = current.representation(using: .jpeg, properties: [.compressionFactor: quality]), jpeg.count <= limit { return jpeg }
            }
            guard let smaller = scaled(current, by: 0.7) else { return nil }
            current = smaller
        }
        return nil
    }

    private static func scaled(_ bitmap: NSBitmapImageRep, by factor: Double) -> NSBitmapImageRep? {
        let width = max(1, Int(Double(bitmap.pixelsWide) * factor)), height = max(1, Int(Double(bitmap.pixelsHigh) * factor))
        guard let target = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: target) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        bitmap.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return target
    }

    func write(_ content: ClipboardContent) async {
        lock.withLock {
            pasteboard.clearContents()
            switch content {
            case .text(let text):
                pasteboard.setString(text, forType: .string)
            case .html(let html):
                pasteboard.setString(html, forType: .html)
                // Offer plain text too, so apps that do not take HTML can still paste.
                // The system's HTML importer is not used: it must run on the main thread and may
                // load what the markup refers to, and this markup comes from outside.
                let plain = MacClipboard.plainText(fromHTML: html)
                if !plain.isEmpty { pasteboard.setString(plain, forType: .string) }
            case .image(let data):
                // The phone sends JPEG, PNG, GIF or BMP unchanged; NSImage sniffs the format.
                if let image = NSImage(data: data) { pasteboard.writeObjects([image]) }
            }
            ownChangeCount = pasteboard.changeCount
        }
    }

    /// Calls `onChange` whenever another app changes the pasteboard. The pasteboard offers no
    /// notification, so this polls the change count, which is cheap.
    func watch(every interval: Duration = .milliseconds(500), onChange: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        Task { [weak self] in
            var seen = self?.changeCount ?? 0
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                let current = self.changeCount
                if current != seen {
                    seen = current
                    if !self.lastChangeWasOurs { await onChange() }
                }
            }
        }
    }

    /// Whether macOS wrote this HTML from rich text, rather than an app or a web page from
    /// its own HTML: the system's writer names itself in the document.
    static func isMadeFromRichText(_ html: String) -> Bool {
        html.range(of: "Cocoa HTML Writer", options: .caseInsensitive) != nil
    }

    /// HTML as the phone should get it: the body only. macOS writes a whole document for text
    /// copied from rich text (Preview, TextEdit: "Cocoa HTML Writer"), with a style sheet in
    /// its head, and the phone makes its plain text with Android's `Html.fromHtml`, which keeps
    /// the text of such parts: the style sheet showed up in front of the pasted words
    /// (2026-10-15). Nil when nothing readable is left.
    static func cleanedHTML(_ html: String) -> String? {
        var body = html
        let options: NSRegularExpression.Options = [.caseInsensitive, .dotMatchesLineSeparators]
        func range(of pattern: String, in text: String) -> Range<String.Index>? {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: options),
                  let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
            return Range(match.range, in: text)
        }
        // Between the body's opening and closing tags, where there is a body.
        if let open = range(of: "<body\\b[^>]*>", in: body) {
            body = String(body[open.upperBound...])
            if let close = range(of: "</body\\s*>", in: body) { body = String(body[..<close.lowerBound]) }
        }
        // And whatever else is not text, wherever it stands.
        for pattern in ["<head\\b[^>]*>.*?</head\\s*>", "<style\\b[^>]*>.*?</style\\s*>", "<script\\b[^>]*>.*?</script\\s*>",
                        "<title\\b[^>]*>.*?</title\\s*>", "<!--.*?-->", "<!doctype[^>]*>", "<meta\\b[^>]*>", "</?html\\b[^>]*>"] {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else { continue }
            body = expression.stringByReplacingMatches(in: body, range: NSRange(body.startIndex..., in: body), withTemplate: "")
        }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return plainText(fromHTML: body).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : body
    }

    /// The text of an HTML fragment: tags dropped, line-ending elements turned into line
    /// breaks, the common entities decoded. Nothing is loaded or run. One pass over the
    /// input, so that markup built to be slow to read costs no more than its length.
    static func plainText(fromHTML html: String) -> String {
        let input = Array(html.unicodeScalars)
        let count = input.count
        var output = String.UnicodeScalarView()
        output.reserveCapacity(count)
        /// The closing tag that ends a part whose content is not text, such as a script.
        var skippingUntil: String?
        /// Set once a search to the end found nothing, so that it is not repeated.
        var noMoreTagEnds = false, noMoreCommentEnds = false
        var lastWasSpace = true

        func breakLine() {
            while let last = output.last, last == " " { output.removeLast() }
            output.append("\n")
            lastWasSpace = true
        }
        func matches(_ text: String, at index: Int) -> Bool {
            var position = index
            for scalar in text.unicodeScalars {
                guard position < count, input[position] == scalar else { return false }
                position += 1
            }
            return true
        }

        var index = 0
        while index < count {
            let scalar = input[index]
            if scalar == "<" {
                if matches("<!--", at: index) {
                    var end: Int?
                    if !noMoreCommentEnds {
                        var probe = index + 4
                        while probe + 2 < count { if input[probe] == "-", input[probe + 1] == "-", input[probe + 2] == ">" { end = probe + 3; break }; probe += 1 }
                        if end == nil { noMoreCommentEnds = true }
                    }
                    // An unclosed comment swallows the rest, as in a browser.
                    index = end ?? count
                    continue
                }
                var close: Int?
                if !noMoreTagEnds {
                    var probe = index + 1
                    while probe < count { if input[probe] == ">" { close = probe; break }; probe += 1 }
                    if close == nil { noMoreTagEnds = true }
                }
                if let close {
                    // The tag's name: letters and digits after an optional slash.
                    var position = index + 1
                    var isClosing = false
                    if position < close, input[position] == "/" { isClosing = true; position += 1 }
                    var name = ""
                    while position < close, name.unicodeScalars.count < 12, input[position].properties.isAlphabetic || ("0"..."9").contains(input[position]) {
                        name.unicodeScalars.append(input[position])
                        position += 1
                    }
                    name = name.lowercased()
                    if let waiting = skippingUntil {
                        if isClosing, name == waiting { skippingUntil = nil }
                    } else if !isClosing, ["script", "style", "head"].contains(name) {
                        skippingUntil = name
                    } else if name == "br" || (isClosing && ["p", "div", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote"].contains(name)) {
                        breakLine()
                    }
                    index = close + 1
                    continue
                }
                // A "<" that opens nothing is text.
            }
            if skippingUntil == nil {
                if scalar.properties.isWhitespace {
                    if !lastWasSpace { output.append(" "); lastWasSpace = true }
                } else {
                    output.append(scalar)
                    lastWasSpace = false
                }
            }
            index += 1
        }
        return decodeEntities(String(output)).split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Decodes the common named entities and the numeric ones, each once, left to right, so
    /// that an escaped entity such as "&amp;lt;" stays the text "&lt;".
    static func decodeEntities(_ text: String) -> String {
        let named: [String: String] = ["nbsp": " ", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "amp": "&"]
        let input = Array(text.unicodeScalars)
        var output = String.UnicodeScalarView()
        output.reserveCapacity(input.count)
        var index = 0
        while index < input.count {
            if input[index] == "&" {
                // An entity is short; look no further than a dozen characters for its end.
                var end = index + 1
                while end < input.count, end - index <= 10, input[end] != ";", input[end] != "&", !input[end].properties.isWhitespace { end += 1 }
                if end < input.count, input[end] == ";", end > index + 1 {
                    var body = String.UnicodeScalarView()
                    body.append(contentsOf: input[(index + 1)..<end])
                    let name = String(body)
                    var replacement: String?
                    if name.hasPrefix("#x") || name.hasPrefix("#X") {
                        replacement = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                    } else if name.hasPrefix("#") {
                        replacement = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                    } else {
                        replacement = named[name.lowercased()]
                    }
                    if let replacement {
                        output.append(contentsOf: replacement.unicodeScalars)
                        index = end + 1
                        continue
                    }
                }
            }
            output.append(input[index])
            index += 1
        }
        return String(output)
    }
}
