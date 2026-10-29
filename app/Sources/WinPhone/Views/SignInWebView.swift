import SwiftUI
import WebKit

/// Microsoft's sign-in page inside the app, for the device-code sign-in.
///
/// The page is Microsoft's own, loaded over HTTPS in a web view that keeps nothing after it
/// closes. The app enters the one-time code for the user and otherwise leaves the page alone: it
/// never reads what is typed there. The account password goes from the user to Microsoft only.
struct SignInWebView: NSViewRepresentable {
    let url: URL
    let code: String
    @Binding var host: String
    @Binding var isLoading: Bool

    /// Hosts the sign-in passes through. The code is only ever entered on one of these.
    static let microsoftHosts = ["microsoft.com", "live.com", "microsoftonline.com", "msauth.net", "msftauth.net"]

    static func isMicrosoft(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return microsoftHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Fills the code field of the device sign-in page and presses its button. Returns whether
    /// a field was found. Runs in an isolated script world, with the code passed as an argument.
    static let fillScript = """
        const field = document.querySelector('input[name="otc"]');
        if (!field || field.value) { return false; }
        field.focus();
        field.value = code;
        field.dispatchEvent(new Event('input', { bubbles: true }));
        field.dispatchEvent(new Event('change', { bubbles: true }));
        const button = document.querySelector('input[type="submit"], button[type="submit"]');
        if (button) { button.click(); }
        return true;
        """

    /// Enters the code on the page the view is showing, if that page is Microsoft's and has
    /// the code field. Reports whether it did.
    @MainActor
    static func enterCode(_ code: String, in webView: WKWebView, completion: @escaping (Bool) -> Void) {
        guard isMicrosoft(webView.url?.host), webView.url?.scheme == "https" else { return completion(false) }
        webView.callAsyncJavaScript(fillScript, arguments: ["code": code], in: nil, in: .defaultClient) { result in
            if case .success(let value) = result, value as? Bool == true { completion(true) } else { completion(false) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Cookies and site data live in memory and vanish with the view.
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        view.load(URLRequest(url: url))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let parent: SignInWebView
        private var codeEntered = false

        init(_ parent: SignInWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            parent.host = webView.url?.host ?? ""
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
            parent.host = webView.url?.host ?? ""
            guard !codeEntered else { return }
            SignInWebView.enterCode(parent.code, in: webView) { [weak self] entered in
                if entered { self?.codeEntered = true }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }

        /// Links that ask for a new window open in this one.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }
    }
}

/// The sign-in step: Microsoft's page in the window, with the code shown as a fallback and the
/// option to finish on another device instead.
struct SignInView: View {
    let code: String
    let url: String
    let expires: Date
    /// False in previews and the demo, where nothing may touch the network.
    let embedsPage: Bool
    /// Draws the frame around an empty page, for rendered previews of the layout.
    var placeholderPage = false
    let cancel: () -> Void

    @State private var host = ""
    @State private var isLoading = true
    @State private var useAnotherDevice = false

    var body: some View {
        if embedsPage || placeholderPage, !useAnotherDevice, let pageURL = URL(string: url) {
            VStack(spacing: 0) {
                header
                Divider()
                if placeholderPage {
                    ZStack { Color.white; Text("Microsoft's sign-in page appears here").foregroundStyle(.gray) }
                        .onAppear { host = "login.live.com"; isLoading = false }
                } else {
                    SignInWebView(url: pageURL, code: code, host: $host, isLoading: $isLoading)
                }
                Divider()
                footer
            }
            .frame(maxWidth: 560, maxHeight: 640)
            .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.separator))
            .shadow(color: .black.opacity(0.14), radius: 22, y: 8)
            .padding(.vertical, -8)
        } else {
            VStack(spacing: 14) {
                SignInCodeView(code: code, url: url, expires: expires, cancel: cancel)
                if embedsPage {
                    Button("Sign in here instead") { useAnotherDevice = false }.buttonStyle(.link)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            let trusted = SignInWebView.isMicrosoft(host)
            Image(systemName: trusted ? "lock.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(trusted ? Color.secondary : Color.orange)
                .accessibilityLabel(trusted ? "Secure Microsoft page" : "Not a Microsoft page")
            VStack(alignment: .leading, spacing: 0) {
                Text("Sign In to Microsoft").font(.headline)
                Text(host.isEmpty ? "Loading…" : host)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if isLoading { ProgressView().controlSize(.small) }
            Button("Cancel", role: .cancel, action: cancel)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.bar)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("Code").font(.footnote).foregroundStyle(.secondary)
            Text(code).font(.footnote.monospaced().weight(.semibold)).textSelection(.enabled)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).help("Copy the code")
            Spacer()
            Button("Use another device") { useAnotherDevice = true }.buttonStyle(.link).font(.footnote)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(.bar)
    }
}
