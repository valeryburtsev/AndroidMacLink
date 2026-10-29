import Foundation
import XCTest
@testable import WinPhoneCore

struct FixtureFrame {
    let fromClient: Bool
    let bytes: Data
}

enum Fixtures {
    static func url(_ name: String) throws -> URL {
        let base = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        return base.appendingPathComponent(name)
    }

    /// Real hub frames captured from Phone Link (c2s) and relayed from Link to Windows (s2c),
    /// sanitized by tools/capture/make_fixtures.py.
    static func relayFrames() throws -> [FixtureFrame] {
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url("relay-frames.json"))) as! [[String: String]]
        return raw.map { FixtureFrame(fromClient: $0["dir"] == "c2s", bytes: Data(hex: $0["hex"]!)) }
    }
}

extension Data {
    init(hex: String) {
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self = data
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
