import AppKit
import WinPhoneCore

/// The ways a link reaches this app from outside its window: the Services menu of any app
/// ("Send Link to Phone", offered when a web address is selected), and an address of the
/// app's own, `winphone://send?url=…`, for shortcuts and scripts.
@MainActor
final class LinkService: NSObject {
    static let shared = LinkService()
    weak var model: AppModel?

    /// Called by the system for the Services menu item; the selection is on the pasteboard.
    @objc func sendLinkToPhone(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let candidates = [pasteboard.string(forType: .URL), pasteboard.string(forType: .string)].compactMap { $0 }
        guard let url = candidates.compactMap(PhoneLinks.link(inCopied:)).first else {
            error.pointee = "The selection is not a web address."
            return
        }
        model?.actions?.sendLink(url)
    }

    /// `winphone://send?url=https://…`.
    func handle(_ address: URL) {
        guard address.scheme?.lowercased() == "winphone", address.host?.lowercased() == "send",
              let value = URLComponents(url: address, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value,
              let url = PhoneLinks.webURL(value) else { return }
        model?.actions?.sendLink(url)
    }
}
