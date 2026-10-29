import XCTest
@testable import WinPhoneCore

/// The hands-free dialogue against a phone that answers as an Android audio gateway does.
/// Numbers here are made up.
final class HandsFreeTests: XCTestCase {
    /// A scripted audio gateway: answers each command as the profile says.
    struct Gateway {
        var features = 3943
        var values = [0, 0, 1, 4, 0, 3, 0]
        var refuses: Set<String> = []
        var calls: [String] = []
        private(set) var heard: [String] = []

        mutating func answer(_ line: String) -> String {
            heard.append(line)
            if refuses.contains(line) { return "\r\nERROR\r\n" }
            switch line {
            case _ where line.hasPrefix("AT+BRSF="): return "\r\n+BRSF: \(features)\r\n\r\nOK\r\n"
            case "AT+CIND=?":
                return "\r\n+CIND: (\"call\",(0,1)),(\"callsetup\",(0-3)),(\"service\",(0-1)),(\"signal\",(0-5)),(\"roam\",(0,1)),(\"battchg\",(0-5)),(\"callheld\",(0-2))\r\n\r\nOK\r\n"
            case "AT+CIND?": return "\r\n+CIND: \(values.map(String.init).joined(separator: ","))\r\n\r\nOK\r\n"
            case "AT+CHLD=?": return "\r\n+CHLD: (0,1,2,3)\r\n\r\nOK\r\n"
            case "AT+CLCC": return calls.map { "\r\n+CLCC: \($0)\r\n" }.joined() + "\r\nOK\r\n"
            default: return "\r\nOK\r\n"
            }
        }
    }

    /// Runs the link against the gateway until neither has anything more to say.
    @discardableResult
    func run(_ link: inout HandsFreeLink, _ gateway: inout Gateway, _ first: HandsFreeLink.Output) -> [HandsFreeLink.Event] {
        var events = first.events
        var pending = first.send
        var rounds = 0
        while !pending.isEmpty, rounds < 50 {
            rounds += 1
            let line = pending.removeFirst()
            let output = link.receive(Data(gateway.answer(line).utf8))
            events += output.events
            pending += output.send
        }
        return events
    }

    func connected(_ gateway: inout Gateway) -> HandsFreeLink {
        var link = HandsFreeLink()
        run(&link, &gateway, link.start())
        return link
    }

    func testOpeningExchangeInTheOrderTheProfileWants() {
        var gateway = Gateway()
        var link = HandsFreeLink()
        let events = run(&link, &gateway, link.start())
        XCTAssertEqual(gateway.heard, ["AT+BRSF=54", "AT+CIND=?", "AT+CIND?", "AT+CMER=3,0,0,1", "AT+CHLD=?", "AT+CLIP=1", "AT+CCWA=1", "AT+CMEE=1"])
        XCTAssertTrue(link.isReady)
        XCTAssertEqual(link.gatewayFeatures, 3943)
        XCTAssertEqual(link.indicatorNames, ["call", "callsetup", "service", "signal", "roam", "battchg", "callheld"])
        XCTAssertEqual(events, [.indicator("service", 1), .indicator("signal", 4), .indicator("roam", 0), .indicator("battchg", 3), .ready])
        XCTAssertNil(link.call)
        XCTAssertFalse(link.isWaiting)
    }

    func testAGatewayWithoutThreeWayCallingIsNotAskedForHoldModes() {
        var gateway = Gateway(features: 3942)
        let link = connected(&gateway)
        XCTAssertFalse(gateway.heard.contains("AT+CHLD=?"))
        XCTAssertTrue(link.isReady)
    }

    func testOneCommandAtATime() {
        var link = HandsFreeLink()
        XCTAssertEqual(link.start().send, ["AT+BRSF=54"])
        XCTAssertEqual(link.answer().send, [], "nothing more goes out before the answer")
        XCTAssertEqual(link.receive(Data("\r\n+BRSF: 3943\r\n".utf8)).send, [])
        XCTAssertEqual(link.receive(Data("\r\nOK\r\n".utf8)).send, ["AT+CIND=?"])
    }

    func testIncomingCallAnsweredAndEnded() {
        var gateway = Gateway()
        var link = connected(&gateway)
        // The phone rings: call setup 1, then RING and the caller's number, repeated.
        var output = link.receive(Data("\r\n+CIEV: 2,1\r\n".utf8))
        XCTAssertEqual(output.events, [.callChanged(LiveCall(phase: .incoming))])
        // With whom is asked for once.
        XCTAssertEqual(output.send, ["AT+CLCC"])
        gateway.calls = ["1,1,4,0,0,\"+15550100\",145"]
        var events = run(&link, &gateway, output)
        XCTAssertEqual(events.last, .callChanged(LiveCall(phase: .incoming, number: "+15550100")))
        output = link.receive(Data("\r\nRING\r\n\r\n+CLIP: \"+15550100\",145,,,\"Someone\"\r\n".utf8))
        XCTAssertEqual(output.events, [.ring], "the same call is not announced again")

        events = run(&link, &gateway, link.answer())
        XCTAssertEqual(gateway.heard.last, "ATA")
        output = link.receive(Data("\r\n+CIEV: 1,1\r\n\r\n+CIEV: 2,0\r\n".utf8))
        XCTAssertEqual(output.events, [.callChanged(LiveCall(phase: .active, number: "+15550100"))])
        XCTAssertEqual(output.send, [], "the number is known")

        run(&link, &gateway, link.hangUp())
        XCTAssertEqual(gateway.heard.last, "AT+CHUP")
        output = link.receive(Data("\r\n+CIEV: 1,0\r\n".utf8))
        XCTAssertEqual(output.events, [.callChanged(nil)])
        XCTAssertNil(link.indicators.number, "the next call starts without a number")
    }

    func testTheCallerShownByClipAloneWhenTheListIsRefused() {
        var gateway = Gateway(refuses: ["AT+CLCC"])
        var link = connected(&gateway)
        let events = run(&link, &gateway, link.receive(Data("\r\n+CIEV: 2,1\r\n".utf8)))
        XCTAssertEqual(events, [.callChanged(LiveCall(phase: .incoming)), .refused("AT+CLCC")])
        let output = link.receive(Data("\r\nRING\r\n\r\n+CLIP: \"5550101\",129\r\n".utf8))
        XCTAssertEqual(output.events, [.ring, .callChanged(LiveCall(phase: .incoming, number: "5550101"))])
    }

    func testRingBeforeAnyIndicatorStillShowsACall() {
        var gateway = Gateway()
        var link = connected(&gateway)
        let output = link.receive(Data("\r\nRING\r\n".utf8))
        XCTAssertEqual(output.events, [.ring, .callChanged(LiveCall(phase: .incoming))])
    }

    func testOutgoingCall() {
        var gateway = Gateway()
        var link = connected(&gateway)
        run(&link, &gateway, link.dial("+1 (555) 01-02"))
        XCTAssertEqual(gateway.heard.last, "ATD+15550102;")
        var output = link.receive(Data("\r\n+CIEV: 2,2\r\n".utf8))
        XCTAssertEqual(output.events, [.callChanged(LiveCall(phase: .dialing, number: "+15550102"))])
        output = link.receive(Data("\r\n+CIEV: 2,3\r\n".utf8))
        XCTAssertEqual(output.events, [.callChanged(LiveCall(phase: .alerting, number: "+15550102"))])
        output = link.receive(Data("\r\n+CIEV: 1,1\r\n\r\n+CIEV: 2,0\r\n".utf8))
        XCTAssertEqual(output.events, [.callChanged(LiveCall(phase: .active, number: "+15550102"))])
        run(&link, &gateway, link.tone("5"))
        XCTAssertEqual(gateway.heard.last, "AT+VTS=5")
        output = link.receive(Data("\r\n+CIEV: 7,2\r\n".utf8))
        XCTAssertEqual(output.events, [.callChanged(LiveCall(phase: .held, number: "+15550102"))])
    }

    func testRefusedDialLeavesNoNumber() {
        var gateway = Gateway(refuses: ["ATD5550103;"])
        var link = connected(&gateway)
        let events = run(&link, &gateway, link.dial("5550103"))
        XCTAssertEqual(events, [.refused("ATD")], "the number is not repeated in what is reported")
        XCTAssertNil(link.indicators.number)
        XCTAssertEqual(link.dial("call me").send, [], "nothing to dial")
        XCTAssertEqual(link.tone("x").send, [])
        XCTAssertEqual(HandsFreeLink.dialable("00 49-30 #31*"), "004930#31*")
    }

    func testACallAlreadyThereWhenConnecting() {
        var gateway = Gateway(values: [1, 0, 1, 4, 0, 3, 0], calls: ["1,0,0,0,0,\"5550104\",129"])
        var link = HandsFreeLink()
        let events = run(&link, &gateway, link.start())
        XCTAssertEqual(gateway.heard.last, "AT+CLCC")
        XCTAssertEqual(events.last, .callChanged(LiveCall(phase: .active, number: "5550104")))
        XCTAssertEqual(link.call, LiveCall(phase: .active, number: "5550104"))
    }

    func testSilenceCountsAsARefusalAndBytesMayArriveInPieces() {
        var link = HandsFreeLink()
        _ = link.start()
        XCTAssertEqual(link.timedOut().send, ["AT+CIND=?"], "a phone that says nothing to the first command is still asked the rest")
        XCTAssertEqual(link.receive(Data("\r\n+CIND: (\"call\",(0,1)),(\"call".utf8)).send, [])
        XCTAssertEqual(link.receive(Data("setup\",(0-3))\r\n\r\nO".utf8)).send, [])
        XCTAssertEqual(link.receive(Data("K\r\n".utf8)).send, ["AT+CIND?"])
        XCTAssertEqual(link.indicatorNames, ["call", "callsetup"])
        XCTAssertEqual(link.timedOut().send, ["AT+CMER=3,0,0,1"])
        XCTAssertEqual(link.receive(Data("\r\nOK\r\n".utf8)).events, [.ready])
    }

    /// Hold is the profile's own; mute is asked about, since most phones do not offer it.
    func testHoldAndTheQuestionAboutMute() {
        var gateway = Gateway()
        var link = connected(&gateway)
        // This gateway, like most, refuses the question.
        gateway.refuses = [HandsFreeLink.muteQuestion]
        var events = run(&link, &gateway, link.askAboutMute())
        XCTAssertEqual(events, [.refused("AT+CMUT")])
        run(&link, &gateway, link.toggleHold())
        XCTAssertEqual(gateway.heard.last, "AT+CHLD=2")
        // A phone that offers it says so with a line of its own before the OK.
        _ = link.askAboutMute()
        events = link.receive(Data("\r\n+CMUT: (0,1)\r\n\r\nOK\r\n".utf8)).events
        XCTAssertEqual(events, [.canMute])
        XCTAssertEqual(link.mute(true).send, ["AT+CMUT=1"])
        _ = link.receive(Data("\r\nOK\r\n".utf8))
        XCTAssertEqual(link.mute(false).send, ["AT+CMUT=0"])
        // The same line unasked means nothing.
        _ = link.receive(Data("\r\nOK\r\n".utf8))
        XCTAssertEqual(link.receive(Data("\r\n+CMUT: 1\r\n".utf8)).events, [])
    }

    func testIndicatorsAddUpToOneCall() {
        XCTAssertNil(CallIndicators().liveCall)
        XCTAssertEqual(CallIndicators(call: 1, setup: 1, number: "1").liveCall, LiveCall(phase: .active, number: "1"), "a second call ringing does not replace the first")
        XCTAssertEqual(CallIndicators(call: 1, held: 1).liveCall?.phase, .active)
        XCTAssertEqual(CallIndicators(call: 1, held: 2).liveCall?.phase, .held)
        var indicators = CallIndicators(call: 1, number: "1")
        indicators.set("call", to: 0)
        XCTAssertNil(indicators.number)
    }
}
