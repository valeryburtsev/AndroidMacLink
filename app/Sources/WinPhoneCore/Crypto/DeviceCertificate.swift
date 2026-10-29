import CryptoKit
import Foundation

/// An ECDSA P-384 key pair with a self-signed certificate. DCG identifies a client by two of
/// these: the auth identity (common name = device ID) and the trust identity
/// (common name = `trust_<dcg client id>`).
public struct DeviceCertificate: Sendable {
    public let privateKey: P384.Signing.PrivateKey
    /// DER-encoded X.509 certificate.
    public let der: Data
    public let commonName: String

    public enum CertificateError: Error { case malformed }

    enum OID {
        static let ecdsaWithSHA384: [UInt] = [1, 2, 840, 10045, 4, 3, 3]
        static let commonName: [UInt] = [2, 5, 4, 3]
        static let keyUsage: [UInt] = [2, 5, 29, 15]
        static let basicConstraints: [UInt] = [2, 5, 29, 19]
    }

    /// Creates a new key and a self-signed certificate for it, with the same structure as the
    /// certificates Phone Link generates: version 3, an 8-byte serial, the common name as a
    /// PrintableString or BMPString (whichever Windows would pick), and two non-critical extensions (empty basic constraints, and key usage
    /// "digital signature").
    /// - Parameters:
    ///   - notBefore: start of validity. Phone Link uses 12 hours in the past to absorb clock skew.
    ///   - notAfter: end of validity. Phone Link uses 365 days ahead.
    public static func generate(commonName: String, notBefore: Date, notAfter: Date,
                                privateKey: P384.Signing.PrivateKey = .init()) throws -> DeviceCertificate {
        let name = DER.sequence(DER.set(DER.sequence(DER.objectIdentifier(OID.commonName), DER.directoryString(commonName))))
        let algorithm = DER.sequence(DER.objectIdentifier(OID.ecdsaWithSHA384))
        var serial = Data((0..<8).map { _ in UInt8.random(in: 0...255) })
        if serial[0] == 0 { serial[0] = 1 }
        let basicConstraints = DER.sequence(DER.objectIdentifier(OID.basicConstraints), DER.octetString(DER.sequence()))
        let keyUsage = DER.sequence(DER.objectIdentifier(OID.keyUsage),
                                    DER.octetString(DER.bitString(Data([0x80]), unusedBits: 7)))
        let tbs = DER.sequence(
            DER.explicit(0, DER.integer(2)),
            DER.integer(serial),
            algorithm,
            name,
            DER.sequence(DER.time(notBefore), DER.time(notAfter)),
            name,
            privateKey.publicKey.derRepresentation,
            DER.explicit(3, DER.sequence(basicConstraints, keyUsage)))
        let signature = try privateKey.signature(for: SHA384.hash(data: tbs))
        let der = DER.sequence(tbs, algorithm, DER.bitString(signature.derRepresentation))
        return DeviceCertificate(privateKey: privateKey, der: der, commonName: commonName)
    }

    /// The validity window Phone Link uses: 12 hours back, 365 days ahead.
    public static func generate(commonName: String, now: Date = Date()) throws -> DeviceCertificate {
        try generate(commonName: commonName, notBefore: now.addingTimeInterval(-12 * 3600),
                     notAfter: now.addingTimeInterval(365 * 86400))
    }

    public init(privateKey: P384.Signing.PrivateKey, der: Data, commonName: String) {
        self.privateKey = privateKey
        self.der = der
        self.commonName = commonName
    }

    /// Standard base64 of the DER bytes, the form DCG uses in JSON bodies and JWT claims.
    public var base64: String { der.base64EncodedString() }

    /// Reads the subject common name and public key out of a DER certificate.
    public static func inspect(der: Data) throws -> (commonName: String?, publicKey: P384.Signing.PublicKey, notAfter: Date?) {
        let certificate = try DER.parse(der).children()
        guard let tbs = try certificate.first?.children(), tbs.count >= 7 else { throw CertificateError.malformed }
        // Fields: [0] version, serial, signature alg, issuer, validity, subject, SPKI, ...
        let offset = tbs[0].tag == 0xA0 ? 0 : -1
        let subject = tbs[5 + offset]
        let spki = tbs[6 + offset]
        var commonName: String?
        for rdn in try subject.children() {
            for attribute in try rdn.children() {
                let parts = try attribute.children()
                if parts.count == 2, parts[0].raw == DER.objectIdentifier(OID.commonName) {
                    // BMPString (0x1E) is UTF-16BE; the other string types are ASCII-compatible.
                    commonName = String(data: parts[1].content, encoding: parts[1].tag == 0x1E ? .utf16BigEndian : .utf8)
                }
            }
        }
        let validity = try tbs[4 + offset].children()
        let notAfter = validity.count == 2 ? parseTime(validity[1]) : nil
        return (commonName, try P384.Signing.PublicKey(derRepresentation: spki.raw), notAfter)
    }

    static func parseTime(_ node: DER.Node) -> Date? {
        guard var text = String(data: node.content, encoding: .ascii) else { return nil }
        if node.tag == 0x17 {
            // UTCTime: two-digit year, 1950 to 2049.
            guard text.count == 13, let year = Int(text.prefix(2)) else { return nil }
            text = (year < 50 ? "20" : "19") + text
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        return formatter.date(from: text)
    }
}

/// A compact JWS signed with ES384, the only JWT form DCG uses with device keys.
public enum JWT {
    public enum Value: Equatable, Sendable {
        case string(String)
        case int(Int64)
    }

    /// The header the Microsoft JWT library emits for a bare ECDSA key.
    static let header = #"{"alg":"ES384","typ":"JWT"}"#

    /// Serializes claims in the given order, escaping only what JSON requires. Base64 text keeps
    /// its `/` and `+`, as in the tokens Phone Link sends.
    static func serialize(_ claims: [(String, Value)]) -> String {
        func quote(_ s: String) -> String {
            var out = "\""
            for scalar in s.unicodeScalars {
                switch scalar {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
                default: out.unicodeScalars.append(scalar)
                }
            }
            return out + "\""
        }
        let members = claims.map { key, value -> String in
            switch value {
            case .string(let s): return quote(key) + ":" + quote(s)
            case .int(let i): return quote(key) + ":" + String(i)
            }
        }
        return "{" + members.joined(separator: ",") + "}"
    }

    /// Signs `claims` with the key. The signature is the raw 96-byte `r || s` form JWS requires.
    public static func signES384(claims: [(String, Value)], key: P384.Signing.PrivateKey) throws -> String {
        let signingInput = Base64URL.encode(Data(header.utf8)) + "." + Base64URL.encode(Data(serialize(claims).utf8))
        let signature = try key.signature(for: SHA384.hash(data: Data(signingInput.utf8)))
        return signingInput + "." + Base64URL.encode(signature.rawRepresentation)
    }

    /// Splits a compact JWS and verifies it against a public key. Returns header and claims.
    public static func verifyES384(_ token: String, key: P384.Signing.PublicKey) -> (header: [String: Any], claims: [String: Any])? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let h = Base64URL.decode(parts[0]), let c = Base64URL.decode(parts[1]),
              let s = Base64URL.decode(parts[2]), let signature = try? P384.Signing.ECDSASignature(rawRepresentation: s),
              key.isValidSignature(signature, for: SHA384.hash(data: Data((parts[0] + "." + parts[1]).utf8))),
              let header = try? JSONSerialization.jsonObject(with: h) as? [String: Any],
              let claims = try? JSONSerialization.jsonObject(with: c) as? [String: Any] else { return nil }
        return (header, claims)
    }
}
