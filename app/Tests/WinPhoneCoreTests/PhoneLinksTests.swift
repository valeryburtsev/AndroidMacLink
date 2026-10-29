import XCTest
@testable import WinPhoneCore

/// Links between the two devices. Addresses here are made up.
final class PhoneLinksTests: XCTestCase {
    func testALinkCopiedOnThePhoneIsToldFromText() {
        XCTAssertEqual(PhoneLinks.link(inCopied: "https://example.com/a?b=1#c")?.absoluteString, "https://example.com/a?b=1#c")
        XCTAssertEqual(PhoneLinks.link(inCopied: "  http://example.com \n")?.host, "example.com")
        // A place's name above its map link, as a maps app copies it.
        XCTAssertEqual(PhoneLinks.link(inCopied: "Blue Cafe\nhttps://maps.example/xyz")?.absoluteString, "https://maps.example/xyz")
        XCTAssertNil(PhoneLinks.link(inCopied: "see https://a.example and https://b.example"), "two links are a text, not a link")
        XCTAssertNil(PhoneLinks.link(inCopied: String(repeating: "word ", count: 60) + "https://example.com"), "a long text that mentions a link")
        XCTAssertNil(PhoneLinks.link(inCopied: "just some words"))
        XCTAssertNil(PhoneLinks.link(inCopied: "example.com"), "no scheme, no certainty")
        XCTAssertNil(PhoneLinks.link(inCopied: "ftp://example.com/file"))
        XCTAssertNil(PhoneLinks.link(inCopied: "javascript:alert(1)"))
        XCTAssertNil(PhoneLinks.link(inCopied: "file:///etc/hosts"))
        XCTAssertNil(PhoneLinks.link(inCopied: "https://"))
        XCTAssertNil(PhoneLinks.link(inCopied: ""))
        // A place as a phone names it.
        XCTAssertEqual(PhoneLinks.link(inCopied: "geo:52.5,13.4?z=15")?.absoluteString, "https://maps.apple.com/?ll=52.5,13.4")
        XCTAssertEqual(PhoneLinks.link(inCopied: "geo:0,0?q=Blue%20Cafe")?.absoluteString, "https://maps.apple.com/?q=Blue%20Cafe")
        XCTAssertNil(PhoneLinks.link(inCopied: "geo:nowhere"))
    }

    func testAppContextsAreReadFromTheirParallelArrays() {
        let push = ValueSet([
            "contentType": .string("continuityAppContext"), "appContextItemCount": .int32(3), "appContextSequenceNumber": .int64(7),
            "appContextIds": .int64Array([1, 2, 3]),
            "appContextAppIds": .stringArray(["com.example.browser", "com.example.notes", "com.example.browser"]),
            "appContextTypes": .stringArray(["BrowserHistory", "ResumeActivity", "BrowserHistory"]),
            "appContextTitles": .stringArray(["A Page", "", "Gone"]),
            "appContextWebLinks": .stringArray(["https://example.com/page", "", "https://example.com/old"]),
            "appContextIntentUris": .stringArray(["", "example-notes:OpenNote?id=1", ""]),
            "appContextActions": .int32Array([0, 0, 2]),
        ])
        let contexts = PhoneAppContext.contexts(in: push)
        XCTAssertEqual(contexts.map(\.id), [1, 2, 3])
        XCTAssertEqual(contexts[0].url?.absoluteString, "https://example.com/page")
        XCTAssertEqual(contexts[0].title, "A Page")
        XCTAssertNil(contexts[1].url, "an app's own address is of no use on another device")
        XCTAssertEqual(contexts.map(\.action), [.update, .update, .delete])
        // A web address as the way back in counts too.
        XCTAssertEqual(PhoneAppContext(id: 9, appId: "a", type: "ResumeActivity", intentUri: "https://example.com/doc").url?.host, "example.com")
        XCTAssertEqual(PhoneAppContext.contexts(in: ValueSet(["contentType": .string("continuityAppContext")])), [])
        // Shorter arrays than ids do not break the reading.
        let ragged = ValueSet(["appContextIds": .int64Array([1, 2]), "appContextAppIds": .stringArray(["a"])])
        XCTAssertEqual(PhoneAppContext.contexts(in: ragged).map(\.appId), ["a", ""])
    }

    /// The phone's push is taken and passed on, and answered as any content is.
    func testAnAppContextPushIsPassedOnAndAnswered() async throws {
        let phone = FakePhone()
        let (messenger, relay) = try await phone.connect()
        let sync = NotificationSync(messenger: messenger, displayName: "Mac", installationId: "INSTALL")
        await sync.start()
        let push = ValueSet(["contentType": .string("continuityAppContext"), "appContextIds": .int64Array([5]), "appContextAppIds": .stringArray(["com.example.browser"]),
                             "appContextTypes": .stringArray(["BrowserHistory"]), "appContextWebLinks": .stringArray(["https://example.com/x"]),
                             "appContextActions": .int32Array([0])])
        phone.deliver(PlatformEnvelope(headers: [("_requestId", "c1"), ("_route", "/legacy/phonecontent")], payload: push.serialized(), convention: .android), type: .app)
        var seen: [PhoneAppContext] = []
        for await change in sync.changes {
            if case .appContexts(let contexts) = change { seen = contexts; break }
        }
        XCTAssertEqual(seen.first?.url?.absoluteString, "https://example.com/x")
        let answered = await waitUntil { phone.responses(to: "c1").count == 1 }
        XCTAssertTrue(answered)
        XCTAssertEqual((try? ValueSet(serialized: phone.responses(to: "c1")[0].payload))?.int("result"), 0)
        await relay.close()
    }

    func testTheLinkPageGoesStraightToItsAddressAndCannotBeBrokenOutOf() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/a?x=1&y=%22%3C/script%3E"))
        let page = String(decoding: PhoneLinks.page(for: url), as: UTF8.self)
        XCTAssertTrue(page.contains(#"<meta http-equiv="refresh" content="0; url=https://example.com/a?x=1&amp;y=%22%3C/script%3E">"#))
        XCTAssertTrue(page.contains(#"<a href="https://example.com/a?x=1&amp;y=%22%3C/script%3E">Open example.com</a>"#))
        XCTAssertEqual(page.components(separatedBy: "</script>").count, 2, "one script, ended once")
        let markup = String(page[..<(page.range(of: "<script>")?.lowerBound ?? page.endIndex)])
        XCTAssertFalse(markup.contains("x=1&y"), "nothing of the address unescaped in the markup")
        // An address that tries to end the script from inside it.
        let hostile = try XCTUnwrap(URL(string: "https://example.com/?q=</script><b>"))
        let other = String(decoding: PhoneLinks.page(for: hostile), as: UTF8.self)
        XCTAssertEqual(other.components(separatedBy: "</script>").count, 2)
        XCTAssertFalse(other.contains("<b>"))
        XCTAssertEqual(PhoneLinks.fileName(for: url), "Link to example.com.html")
        XCTAssertEqual(PhoneLinks.fileName(for: try XCTUnwrap(URL(string: "https://www.sub.example.org/x"))), "Link to sub.example.org.html")
    }
}
