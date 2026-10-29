import CryptoKit
import Foundation
import Security
import SwiftProtobuf

// Instant Hotspot: the computer asks the phone to switch on its Wi-Fi hotspot and to say what
// the network is called and what its password is (`protocol/specs/hotspot.md`). The request
// does not travel over the relay but over a Bluetooth channel of the phone's own, one request
// and one answer per connection. It is signed with this device's trust key; the answer is
// signed with the phone's, and the name and password in it are encrypted to a key made for
// this one request.

/// What the phone's hotspot is called and how to get in.
public struct HotspotCredentials: Equatable, Sendable {
    public var ssid: String
    public var password: String

    public init(ssid: String, password: String) {
        self.ssid = ssid
        self.password = password
    }

    /// Whether these can be a Wi-Fi network's: a name of 1 to 32 characters and a password
    /// of 8 to 63, as Phone Link checks them.
    public var isPlausible: Bool { (1...32).contains(ssid.count) && (8...63).contains(password.count) }
}

/// Why the phone cannot share its connection right now, by the phone's own numbers.
public enum HotspotObstacle: Int, Sendable {
    case unknown = 1, airplaneMode = 3, blockedByPolicy = 4, dataNotAllowed = 5, dataSaver = 6, passwordNotSet = 7, noHotspotOnPhone = 8
    case simNotReady = 9, smartViewInUse = 10, unsupportedDataPlan = 11, wifiDirectInUse = 12, wirelessDexInUse = 13
    case linkToWindowsOff = 14, bluetoothPermissionMissing = 15, noHotspotManager = 16, unknownMapping = 17

    public var explanation: String {
        switch self {
        case .airplaneMode: return "The phone is in airplane mode."
        case .blockedByPolicy: return "The phone's hotspot is blocked by a policy."
        case .dataNotAllowed: return "Mobile data is switched off on the phone."
        case .dataSaver: return "Data saver is on on the phone; the hotspot cannot be used with it."
        case .passwordNotSet: return "The phone's hotspot has no password yet. Set one in the phone's hotspot settings."
        case .noHotspotOnPhone, .noHotspotManager: return "This phone has no hotspot to share."
        case .simNotReady: return "The phone's SIM card is not ready."
        case .smartViewInUse: return "Smart View is in use on the phone."
        case .unsupportedDataPlan: return "The phone's data plan does not allow a hotspot."
        case .wifiDirectInUse: return "Wi-Fi Direct is in use on the phone."
        case .wirelessDexInUse: return "Wireless DeX is in use on the phone."
        case .linkToWindowsOff: return "Link to Windows is switched off on the phone."
        case .bluetoothPermissionMissing: return "Link to Windows may not use Bluetooth on the phone. Allow it in the phone's Link to Windows settings."
        case .unknown, .unknownMapping: return "The phone cannot share its connection right now."
        }
    }
}

public enum HotspotError: Error, Equatable {
    /// The phone cannot switch its hotspot on, and says why where it knows.
    case notCapable(HotspotObstacle?)
    /// The phone does not take this computer for one it trusts.
    case untrusted
    /// The phone refused: its status and, where it gave one, its kind of error.
    case refused(status: Int, error: Int)
    /// The answer could not be read.
    case malformed
    /// The answer is not the phone's, or not to this request.
    case forged
    /// The name or password that came out make no Wi-Fi network.
    case implausible
}

/// The messages of the phone's side channel are sent one after the other, each with its
/// length in front as a protobuf varint.
public enum SideChannelFraming {
    public static func frame(_ message: Data) -> Data {
        var framed = Data()
        var length = UInt32(message.count)
        while length >= 0x80 {
            framed.append(UInt8(length & 0x7F) | 0x80)
            length >>= 7
        }
        framed.append(UInt8(length))
        return framed + message
    }

    /// Takes one whole message off the front of what has arrived; nil while it is incomplete.
    /// - Throws: for a length that cannot be right.
    public static func take(from buffer: inout Data, limit: Int = 1 << 20) throws -> Data? {
        var length = 0, shift = 0, index = buffer.startIndex
        while true {
            guard index < buffer.endIndex else { return nil }
            let byte = buffer[index]
            index += 1
            length |= Int(byte & 0x7F) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
            guard shift < 35 else { throw HotspotError.malformed }
        }
        guard length <= limit else { throw HotspotError.malformed }
        guard buffer.endIndex - index >= length else { return nil }
        let message = buffer.subdata(in: index..<(index + length))
        buffer.removeSubrange(buffer.startIndex..<(index + length))
        return message
    }
}

/// The side channel's plainest question: which services it has. It needs no signature and
/// switches nothing on, so an answer to it shows that the phone reads what arrives at all.
public enum SideChannelCapabilities {
    public static var request: Data {
        var message = SideChannel_V1_SideChannelClientRequest()
        message.capabilityRequest = SideChannel_V1_SideChannelCapabilityRequest()
        return SideChannelFraming.frame((try? message.serializedData()) ?? Data())
    }

    /// The services named in the answer, by their numbers in the protocol.
    public static func services(in answer: Data) throws -> [Int] {
        guard let message = try? SideChannel_V1_SideChannelServerMessage(serializedBytes: answer), message.requestResponse.ok else { throw HotspotError.malformed }
        return message.requestResponse.capabilityResponse.capabilities.map(\.rawValue)
    }
}

/// An RSA key made for one request: the phone encrypts the name and password to it.
public final class HotspotKey: @unchecked Sendable {
    private let key: SecKey
    /// The public half as the phone wants it: a DER `SubjectPublicKeyInfo`.
    public let publicKeyInfo: Data

    public init(bits: Int = 2048) throws {
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: bits] as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(key), let plain = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw HotspotError.malformed
        }
        self.key = key
        publicKeyInfo = HotspotKey.publicKeyInfo(wrapping: plain)
    }

    /// The system gives the bare key (PKCS #1); the phone reads it with the algorithm named in front.
    static func publicKeyInfo(wrapping key: Data) -> Data {
        func length(_ count: Int) -> [UInt8] {
            if count < 0x80 { return [UInt8(count)] }
            if count < 0x100 { return [0x81, UInt8(count)] }
            return [0x82, UInt8(count >> 8), UInt8(count & 0xFF)]
        }
        // rsaEncryption, with its empty parameters.
        let algorithm: [UInt8] = [0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00]
        let bits = [0x03] + length(key.count + 1) + [0x00] + [UInt8](key)
        return Data([0x30] + length(algorithm.count + bits.count) + algorithm + bits)
    }

    /// Opens what the phone encrypted to this key (RSA-OAEP with SHA-256 throughout).
    public func decrypt(_ ciphertext: Data) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let plain = SecKeyCreateDecryptedData(key, .rsaEncryptionOAEPSHA256, ciphertext as CFData, &error) as Data? else { throw HotspotError.forged }
        return plain
    }
}

/// One request to the phone's hotspot service and the reading of its answer. Holds what the
/// answer has to be checked against: the nonce, the one-time key, the phone's certificate.
public struct HotspotExchange: Sendable {
    public enum Kind: Sendable {
        /// Whether the phone could share its connection now. Switches nothing on.
        case status
        /// Switches the hotspot on and asks for its name and password.
        case credentials
    }

    public enum Answer: Equatable, Sendable {
        /// The phone could share its connection.
        case capable
        case credentials(HotspotCredentials)
    }

    public let kind: Kind
    /// What goes to the phone: one framed message.
    public let request: Data
    let nonce: String
    let key: HotspotKey?
    let phoneCertificate: Data

    /// - Parameters:
    ///   - ownId: this device's DCG client ID, by which the phone finds whom it trusts.
    ///   - trust: this device's trust key and certificate; the request is signed with it.
    ///   - phoneCertificate: the phone's trust certificate, to check its answer with.
    public init(kind: Kind, ownId: String, trust: DeviceCertificate, phoneCertificate: Data, now: Date = Date()) throws {
        self.kind = kind
        self.phoneCertificate = phoneCertificate
        var random = [UInt8](repeating: 0, count: 128)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw HotspotError.malformed }
        nonce = Data(random).base64EncodedString()
        var entries = [("DCG-Environment", "Prod"), ("nonce", nonce)]
        if kind == .credentials {
            let key = try HotspotKey()
            self.key = key
            entries.append(("publicKey", key.publicKeyInfo.base64EncodedString()))
        } else {
            key = nil
        }
        var message = SideChannel_V1_SideChannelClientRequest()
        message.context.traceID = TraceContext.randomHex(bytes: 16)
        message.context.parentID = TraceContext.randomHex(bytes: 8)
        message.context.correlationID = TraceContext.randomHex(bytes: 8)
        message.hotspotRequest.type = kind == .status ? .capableStatus : .credentials
        message.authorization.signedJwtPayload = try DeviceTokens.trustJWT(scope: "hotspot.request", data: DeviceTokens.wakeDataText(entries), sourceId: ownId, trust: trust, now: now)
        request = SideChannelFraming.frame(try message.serializedData())
    }

    /// Reads the phone's answer: one message, without its length.
    public func answer(_ message: Data) throws -> Answer {
        guard let parsed = try? SideChannel_V1_SideChannelServerMessage(serializedBytes: message), case .requestResponse(let response)? = parsed.body else {
            throw HotspotError.malformed
        }
        let hotspot = response.hotspotResponse
        guard response.ok, hotspot.status == .success else {
            // Numbers only: which of its reasons the phone had (`protocol/specs/hotspot.md`).
            diag("hotspot", "the phone's answer: ok \(response.ok), status \(hotspot.status.rawValue), kind of error \(response.error.type.rawValue), its own state \(hotspot.hasReservation ? String(hotspot.reservation.status.rawValue) : "not said"), for a request of type \(hotspot.type.rawValue)")
            if hotspot.status == .untrusted || response.error.type == .cryptoTrustError { throw HotspotError.untrusted }
            if hotspot.status == .notHotspotCapable || (hotspot.hasReservation && hotspot.reservation.status.rawValue > 2) {
                throw HotspotError.notCapable(HotspotObstacle(rawValue: hotspot.reservation.status.rawValue))
            }
            throw HotspotError.refused(status: hotspot.status.rawValue, error: response.error.type.rawValue)
        }
        // The answer must be to this very request.
        guard hotspot.reservation.nonce == nonce else { throw HotspotError.forged }
        if hotspot.reservation.status.rawValue > 2 { throw HotspotError.notCapable(HotspotObstacle(rawValue: hotspot.reservation.status.rawValue)) }
        guard kind == .credentials, let key else { return .capable }

        // The name and password come inside a token the phone signed with its trust key.
        guard let phoneKey = try? DeviceCertificate.inspect(der: phoneCertificate).publicKey,
              let token = JWT.verifyES384(response.authorization.signedJwtPayload, key: phoneKey),
              token.claims["Scope"] as? String == "hotspot.response" else { throw HotspotError.forged }
        guard let text = token.claims["Data"] as? String, let data = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let sealed = (data["encryptedCredentials"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let nameLength = (data["encryptedSsidLength"] as? String).flatMap(Int.init) ?? (data["encryptedSsidLength"] as? NSNumber)?.intValue else {
            throw HotspotError.malformed
        }
        // Name and password one after the other; the length says where the name ends, counted
        // as the phone counts characters.
        let both = Array(String(decoding: try key.decrypt(sealed), as: UTF8.self).utf16)
        guard nameLength > 0, nameLength < both.count else { throw HotspotError.implausible }
        let credentials = HotspotCredentials(ssid: String(decoding: both[..<nameLength], as: UTF16.self), password: String(decoding: both[nameLength...], as: UTF16.self))
        guard credentials.isPlausible else { throw HotspotError.implausible }
        return .credentials(credentials)
    }
}

/// Whether the phone is set up for its hotspot to be asked for, as its status says.
public struct HotspotReadiness: Equatable, Sendable {
    /// The phone's user has agreed to computers switching the hotspot on.
    public var consent: Bool
    /// The phone's Bluetooth channel for such requests is open.
    public var channelOpen: Bool

    public init(consent: Bool = false, channelOpen: Bool = false) {
        self.consent = consent
        self.channelOpen = channelOpen
    }

    public var isReady: Bool { consent && channelOpen }
}
