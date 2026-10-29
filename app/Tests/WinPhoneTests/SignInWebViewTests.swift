import WebKit
import XCTest
@testable import WinPhone

/// The in-app sign-in enters the one-time code on Microsoft's page and nowhere else. The page
/// here is a local stand-in with the same form as the real one; nothing touches the network.
@MainActor
final class SignInWebViewTests: XCTestCase {
    final class Loader: NSObject, WKNavigationDelegate {
        var finished: (() -> Void)?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished?() }
    }

    /// The real page's form: a text input named `otc` and a submit input.
    static let page = """
        <html><body><form onsubmit="document.title = 'submitted:' + this.otc.value; return false;">
        <input type="hidden" name="flow" value="x"><input type="text" name="otc" maxlength="16" placeholder="Enter code">
        <input type="submit" value="Next"></form></body></html>
        """

    func load(_ html: String, base: String) async -> (WKWebView, Loader) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let loader = Loader()
        view.navigationDelegate = loader
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            loader.finished = { continuation.resume() }
            view.loadHTMLString(html, baseURL: URL(string: base))
        }
        loader.finished = nil
        return (view, loader)
    }

    func enter(_ code: String, in view: WKWebView) async -> Bool {
        await withCheckedContinuation { continuation in
            SignInWebView.enterCode(code, in: view) { continuation.resume(returning: $0) }
        }
    }

    func testCodeIsEnteredAndSubmittedOnMicrosoftsPage() async throws {
        let (view, loader) = await load(Self.page, base: "https://login.live.com/oauth20_remoteconnect.srf")
        _ = loader
        let entered = await enter("ABCD1234", in: view)
        XCTAssertTrue(entered)
        let title = try await view.evaluateJavaScript("document.title") as? String
        XCTAssertEqual(title, "submitted:ABCD1234", "the field was filled and the form's button pressed")
        // A second pass leaves a filled field alone.
        let again = await enter("ZZZZ", in: view)
        XCTAssertFalse(again)
    }

    func testCodeIsNotEnteredOnOtherSites() async throws {
        for base in ["https://login.live.com.example.org/", "https://example.com/", "http://login.live.com/"] {
            let (view, loader) = await load(Self.page, base: base)
            _ = loader
            let entered = await enter("ABCD1234", in: view)
            XCTAssertFalse(entered, base)
            let value = try await view.evaluateJavaScript("document.querySelector('input[name=otc]').value") as? String
            XCTAssertEqual(value, "", base)
        }
    }

    func testPagesWithoutACodeFieldAreLeftAlone() async throws {
        let (view, loader) = await load("<html><body><input type='password' name='passwd'></body></html>", base: "https://login.live.com/")
        _ = loader
        let entered = await enter("ABCD1234", in: view)
        XCTAssertFalse(entered)
        let value = try await view.evaluateJavaScript("document.querySelector('input').value") as? String
        XCTAssertEqual(value, "", "the script never writes into any other field")
    }

    func testMicrosoftHostCheck() {
        XCTAssertTrue(SignInWebView.isMicrosoft("login.live.com"))
        XCTAssertTrue(SignInWebView.isMicrosoft("www.microsoft.com"))
        XCTAssertTrue(SignInWebView.isMicrosoft("login.microsoftonline.com"))
        XCTAssertFalse(SignInWebView.isMicrosoft("microsoft.com.evil.example"))
        XCTAssertFalse(SignInWebView.isMicrosoft("notmicrosoft.com"))
        XCTAssertFalse(SignInWebView.isMicrosoft(nil))
    }
}
