import CryptoKit
import XCTest
@testable import WinPhoneCore

final class CryptoTests: XCTestCase {
    func testDERPrimitives() {
        XCTAssertEqual(DER.integer(2).hex, "020102")
        XCTAssertEqual(DER.integer(Data([0x80])).hex, "02020080")
        XCTAssertEqual(DER.integer(Data([0, 0, 0x7F])).hex, "02017f")
        XCTAssertEqual(DER.objectIdentifier([1, 2, 840, 10045, 4, 3, 3]).hex, "06082a8648ce3d040303")
        XCTAssertEqual(DER.objectIdentifier([2, 5, 4, 3]).hex, "0603550403")
        XCTAssertEqual(DER.encode(tag: 0x04, Data(repeating: 1, count: 200)).prefix(3).hex, "0481c8")
        XCTAssertEqual(DER.encode(tag: 0x04, Data(repeating: 1, count: 300)).prefix(4).hex, "0482012c")
        XCTAssertEqual(String(data: DER.time(Date(timeIntervalSince1970: 1_791_534_262)).dropFirst(2), encoding: .ascii), "261009082422Z")
    }

    func testSelfSignedCertificateIsWellFormed() throws {
        let now = Date(timeIntervalSince1970: 1_791_534_262)
        let commonName = "trust_3f2c1a2e-0000-4000-8000-0123456789ab"
        let certificate = try DeviceCertificate.generate(commonName: commonName, now: now)
        let parsed = try DeviceCertificate.inspect(der: certificate.der)
        XCTAssertEqual(parsed.commonName, commonName)
        XCTAssertEqual(parsed.publicKey.rawRepresentation, certificate.privateKey.publicKey.rawRepresentation)
        XCTAssertEqual(parsed.notAfter, now.addingTimeInterval(365 * 86400))

        // The outer signature must verify over the to-be-signed part with the embedded key.
        let outer = try DER.parse(certificate.der).children()
        XCTAssertEqual(outer.count, 3)
        let signature = try P384.Signing.ECDSASignature(derRepresentation: outer[2].content.dropFirst())
        XCTAssertTrue(parsed.publicKey.isValidSignature(signature, for: SHA384.hash(data: outer[0].raw)))

        // The system's own X.509 parser must accept it and see the same subject.
        let secCertificate = try XCTUnwrap(SecCertificateCreateWithData(nil, certificate.der as CFData))
        XCTAssertEqual(SecCertificateCopySubjectSummary(secCertificate) as String?, commonName)
    }

    /// Structure observed in a real Phone Link trust certificate (capture of 2026-10-09):
    /// same field order, BMPString name, UTCTime validity of -12 h / +365 d, 8-byte serial,
    /// and extensions `basicConstraints = 3000`, `keyUsage = 03020780`, neither critical.
    func testCertificateMatchesPhoneLinkStructure() throws {
        let now = Date(timeIntervalSince1970: 1_791_534_320)
        let certificate = try DeviceCertificate.generate(commonName: "trust_3f2c1a2e-0000-4000-8000-0123456789ab", now: now)
        let tbs = try DER.parse(certificate.der).children()[0].children()
        XCTAssertEqual(tbs.map(\.tag), [0xA0, 0x02, 0x30, 0x30, 0x30, 0x30, 0x30, 0xA3])
        XCTAssertEqual(tbs[0].content.hex, "020102", "version 3")
        XCTAssertLessThanOrEqual(tbs[1].content.count, 9)
        XCTAssertGreaterThanOrEqual(tbs[1].content.count, 8)
        XCTAssertEqual(tbs[2].raw.hex, "300a06082a8648ce3d040303", "ecdsa-with-SHA384, no parameters")
        let nameValue = try tbs[3].children()[0].children()[0].children()[1]
        XCTAssertEqual(nameValue.tag, 0x1E, "BMPString, because of the underscore")
        XCTAssertEqual(nameValue.content.count, 84, "42 UTF-16 code units")
        XCTAssertEqual(tbs[3].raw, tbs[5].raw, "issuer equals subject")
        let validity = try tbs[4].children()
        XCTAssertEqual(validity.map(\.tag), [0x17, 0x17])
        XCTAssertEqual(String(data: validity[0].content, encoding: .ascii), "261008202520Z")
        XCTAssertEqual(String(data: validity[1].content, encoding: .ascii), "271009082520Z")
        XCTAssertEqual(tbs[6].raw.count, 120, "P-384 SubjectPublicKeyInfo")
        XCTAssertEqual(tbs[7].content.hex, "3018" + "30090603551d1304023000" + "300b0603551d0f040403020780")
        // The real certificate is 528 or 529 bytes; ours differs only by signature length.
        XCTAssertTrue((524...530).contains(certificate.der.count), "\(certificate.der.count)")
    }

    func testInspectReadsARealStyleAndroidCertificate() throws {
        // Link to Windows certificates use a UTF-8 name and carry no extensions.
        let key = P384.Signing.PrivateKey()
        let name = DER.sequence(DER.set(DER.sequence(DER.objectIdentifier([2, 5, 4, 3]), DER.utf8String("trust_abc"))))
        let algorithm = DER.sequence(DER.objectIdentifier([1, 2, 840, 10045, 4, 3, 3]))
        let tbs = DER.sequence(DER.explicit(0, DER.integer(2)), DER.integer(Data([1, 2, 3])), algorithm, name,
                               DER.sequence(DER.time(Date(timeIntervalSince1970: 0)), DER.time(Date(timeIntervalSince1970: 1_800_000_000))),
                               name, key.publicKey.derRepresentation)
        let der = DER.sequence(tbs, algorithm, DER.bitString(try key.signature(for: SHA384.hash(data: tbs)).derRepresentation))
        let parsed = try DeviceCertificate.inspect(der: der)
        XCTAssertEqual(parsed.commonName, "trust_abc")
        XCTAssertEqual(parsed.publicKey.rawRepresentation, key.publicKey.rawRepresentation)
    }

    func testJWTSignsAndVerifies() throws {
        let key = P384.Signing.PrivateKey()
        let token = try JWT.signES384(claims: [("Nonce", .string("abc/def+ghi=")), ("exp", .int(1_791_577_462)), ("iss", .string("device"))], key: key)
        let parts = token.split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(String(data: Base64URL.decode(parts[0])!, encoding: .utf8), #"{"alg":"ES384","typ":"JWT"}"#)
        XCTAssertEqual(parts[0].count, 36, "27-byte header")
        XCTAssertEqual(String(data: Base64URL.decode(parts[1])!, encoding: .utf8), #"{"Nonce":"abc/def+ghi=","exp":1791577462,"iss":"device"}"#,
                       "claims keep their order and base64 text is not escaped")
        XCTAssertEqual(Base64URL.decode(parts[2])?.count, 96, "ES384 signatures are raw r||s")
        XCTAssertFalse(token.contains("="))
        let verified = try XCTUnwrap(JWT.verifyES384(token, key: key.publicKey))
        XCTAssertEqual(verified.header["alg"] as? String, "ES384")
        XCTAssertEqual(verified.claims["Nonce"] as? String, "abc/def+ghi=")
        XCTAssertNil(JWT.verifyES384(token, key: P384.Signing.PrivateKey().publicKey))
        XCTAssertNil(JWT.verifyES384(token.dropLast(2) + "AA", key: key.publicKey))
    }

    func testJSONStringEscaping() {
        XCTAssertEqual(JWT.serialize([("a", .string("x\"y\\z\r\n\u{1}"))]), #"{"a":"x\"y\\z\r\n\u0001"}"#)
    }

    /// The nonce JWT Phone Link sends is 1160 characters with a 432-byte certificate, a 44-character
    /// nonce and a 36-character device ID. Ours must come out the same length.
    func testNonceJWTHasTheLengthSeenOnTheWire() throws {
        let deviceId = "3f2c1a2e-0000-4000-8000-0123456789ab"
        let now = Date(timeIntervalSince1970: 1_791_534_262)
        var lengths: Set<Int> = []
        for _ in 0..<12 {
            let identity = try DeviceCertificate.generate(commonName: deviceId, now: now)
            // DER signature length varies by a byte or two; the certificate is 430 to 432 bytes.
            guard identity.der.count == 432 else { continue }
            let token = try DeviceTokens.nonceJWT(nonce: "9LhTym5K8j9GG4FQ66ALf3mT629m67WFSzHVLIOOc5o=", identity: identity, now: now)
            lengths.insert(token.count)
            let claims = try XCTUnwrap(JWT.verifyES384(token, key: identity.privateKey.publicKey)?.claims)
            XCTAssertEqual(claims["iss"] as? String, deviceId)
            XCTAssertEqual(claims["nbf"] as? Int, 1_791_534_262 - 43_200)
            XCTAssertEqual(claims["exp"] as? Int, 1_791_534_262 + 43_200)
            XCTAssertEqual(claims["iat"] as? Int, 1_791_534_262)
            XCTAssertEqual(Data(base64Encoded: claims["Certificate"] as! String), identity.der)
        }
        XCTAssertEqual(lengths, [1160])
    }

    func testIdentityCertificateUsesPrintableStringAndTrustUsesBMPString() throws {
        func nameTag(_ commonName: String) throws -> UInt8 {
            let certificate = try DeviceCertificate.generate(commonName: commonName)
            return try DER.parse(certificate.der).children()[0].children()[3].children()[0].children()[0].children()[1].tag
        }
        XCTAssertEqual(try nameTag("3f2c1a2e-0000-4000-8000-0123456789ab"), 0x13)
        XCTAssertEqual(try nameTag("trust_3f2c1a2e-0000-4000-8000-0123456789ab"), 0x1E)
    }

    /// Five wake requests were captured. The token length in each depends on the region name and
    /// the two flags, which pins down the claim set and the indented CRLF form of the `Data` claim.
    func testWakeJWTHasTheLengthsSeenOnTheWire() throws {
        let deviceId = "3f2c1a2e-0000-4000-8000-0123456789ab"
        let trust = try DeviceCertificate.generate(commonName: "trust_" + deviceId)
        let now = Date(timeIntervalSince1970: 1_791_534_262)
        let observed: [(region: String, ignoreDisabled: Bool, length: Int)] = [
            ("PolandCentral", true, 634), ("NorthEurope", false, 633), ("WestEurope", true, 630),
            ("WestEurope", false, 632), ("NorthEurope", true, 632),
        ]
        for sample in observed {
            let request = try DeviceTokens.wakeRequest(targetDeviceId: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", sourceDeviceId: deviceId,
                                                       hubRegion: sample.region, trust: trust, ignoreDisabledStatus: sample.ignoreDisabled, now: now)
            XCTAssertEqual(request.data["DCG-CryptoWakeJwt"]?.count, sample.length, "\(sample.region), ignoreDisabled=\(sample.ignoreDisabled)")
        }
    }

    func testWakeRequestContents() throws {
        let deviceId = "3f2c1a2e-0000-4000-8000-0123456789ab"
        let trust = try DeviceCertificate.generate(commonName: "trust_" + deviceId)
        let request = try DeviceTokens.wakeRequest(targetDeviceId: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", sourceDeviceId: deviceId,
                                                   hubRegion: "NorthEurope", trust: trust)
        XCTAssertEqual(request.collapseKey, "YPPWake")
        XCTAssertEqual(request.priority, "normal")
        XCTAssertEqual(request.ttl, 20)
        XCTAssertEqual(request.deviceId, "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
        XCTAssertEqual(Set(request.data.keys), ["DCG-Environment", "IgnoreDeviceDisabledStatus", "DCG-RequestNewSession", "DCG-HubRegion", "DCG-CryptoWakeJwt"])
        let jwt = try XCTUnwrap(request.data["DCG-CryptoWakeJwt"])
        let claims = try XCTUnwrap(JWT.verifyES384(jwt, key: trust.privateKey.publicKey)?.claims)
        XCTAssertEqual(claims["iss"] as? String, "trust_" + deviceId)
        XCTAssertEqual(claims["SourceId"] as? String, deviceId)
        XCTAssertEqual(claims["Scope"] as? String, "wake")
        let data = try XCTUnwrap(claims["Data"] as? String)
        XCTAssertTrue(data.hasPrefix("{\r\n  \"DCG-Environment\": \"Prod\",\r\n"))
        let parsed = try JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: String]
        XCTAssertEqual(parsed, ["DCG-Environment": "Prod", "IgnoreDeviceDisabledStatus": "False", "DCG-RequestNewSession": "True", "DCG-HubRegion": "NorthEurope"])
        XCTAssertNil(parsed?["DCG-CryptoWakeJwt"], "the token is not part of what it signs")
        XCTAssertEqual(try DeviceTokens.wakeRequest(targetDeviceId: "t", sourceDeviceId: deviceId, hubRegion: nil, trust: trust, highPriority: true).priority, "high")
    }

    func testBase64URL() {
        let data = Data([0xFB, 0xFF, 0xFE, 0x01])
        XCTAssertEqual(Base64URL.encode(data), "-__-AQ")
        XCTAssertEqual(Base64URL.decode("-__-AQ"), data)
    }
}
