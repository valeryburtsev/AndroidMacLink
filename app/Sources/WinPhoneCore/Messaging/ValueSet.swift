import Foundation
import SwiftProtobuf

/// A typed key-value map, the payload of every APP message. On the wire it is the protobuf
/// `pbvalueset.ValueSet`: each value names its type and fills exactly one typed field.
public struct ValueSet: Equatable, Sendable {
    public enum Value: Equatable, Sendable {
        case int32(Int32)
        case int64(Int64)
        case uint32(UInt32)
        case double(Double)
        case bool(Bool)
        case string(String)
        case int32Array([Int32])
        case int64Array([Int64])
        case stringArray([String])
        /// Raw bytes, such as an image or several thumbnails laid end to end.
        case bytes(Data)
        case boolArray([Bool])
        case object(ValueSet)
        /// A type this client does not model, kept as received.
        case other(Pbvalueset_DataVariant)
    }

    /// The contract version both clients send. The phone accepts a request only when the
    /// integer part matches.
    public static let contractVersion = 3.99

    public var entries: [String: Value]

    public init(_ entries: [String: Value] = [:]) {
        self.entries = entries
    }

    public subscript(key: String) -> Value? {
        get { entries[key] }
        set { entries[key] = newValue }
    }

    public func string(_ key: String) -> String? { if case .string(let v)? = entries[key] { return v }; return nil }
    public func bool(_ key: String) -> Bool? { if case .bool(let v)? = entries[key] { return v }; return nil }
    public func double(_ key: String) -> Double? { if case .double(let v)? = entries[key] { return v }; return nil }
    public func strings(_ key: String) -> [String]? { if case .stringArray(let v)? = entries[key] { return v }; return nil }
    public func int32s(_ key: String) -> [Int32]? { if case .int32Array(let v)? = entries[key] { return v }; return nil }
    public func int64s(_ key: String) -> [Int64]? { if case .int64Array(let v)? = entries[key] { return v }; return nil }
    public func bytes(_ key: String) -> Data? { if case .bytes(let v)? = entries[key] { return v }; return nil }
    public func bools(_ key: String) -> [Bool]? { if case .boolArray(let v)? = entries[key] { return v }; return nil }
    public func object(_ key: String) -> ValueSet? { if case .object(let v)? = entries[key] { return v }; return nil }

    /// Splits a byte value into consecutive pieces of the given sizes, as used for thumbnails.
    /// Returns nil when the sizes do not add up to the data.
    public static func split(_ data: Data, sizes: [Int64]) -> [Data]? {
        // The sizes come from the phone: add them without trusting that the sum fits.
        var total: Int64 = 0
        for size in sizes {
            let (sum, overflow) = total.addingReportingOverflow(size)
            guard size >= 0, !overflow else { return nil }
            total = sum
        }
        guard total == Int64(data.count) else { return nil }
        var pieces: [Data] = [], index = data.startIndex
        for size in sizes {
            let end = index + Int(size)
            pieces.append(Data(data[index..<end]))
            index = end
        }
        return pieces
    }

    public func int(_ key: String) -> Int? {
        switch entries[key] {
        case .int32(let v)?: return Int(v)
        case .int64(let v)?: return Int(v)
        case .uint32(let v)?: return Int(v)
        default: return nil
        }
    }

    // MARK: Wire form

    public func serialized() -> Data {
        (try? message.serializedData()) ?? Data()
    }

    public init(serialized data: Data) throws {
        self.init(try Pbvalueset_ValueSet(serializedBytes: data))
    }

    var message: Pbvalueset_ValueSet {
        var out = Pbvalueset_ValueSet()
        for (key, value) in entries {
            var variant = Pbvalueset_DataVariant()
            switch value {
            case .int32(let v): variant.valueType = .int32; variant.int32Value = v
            case .int64(let v): variant.valueType = .int64; variant.int64Value = v
            case .uint32(let v): variant.valueType = .uint32; variant.uint32Value = v
            case .double(let v): variant.valueType = .double; variant.doubleValue = v
            case .bool(let v): variant.valueType = .bool; variant.boolValue = v
            case .string(let v): variant.valueType = .string; variant.stringValue = v
            case .int32Array(let v): variant.valueType = .int32Array; variant.int32Array = v
            case .int64Array(let v): variant.valueType = .int64Array; variant.int64Array = v
            case .stringArray(let v): variant.valueType = .stringArray; variant.stringArray = v
            case .bytes(let v): variant.valueType = .uint8Array; variant.uint8Array = v
            case .boolArray(let v): variant.valueType = .boolArray; variant.boolArray = v
            case .object(let v): variant.valueType = .object; variant.objectValue = v.message
            case .other(let v): variant = v
            }
            out.entries[key] = variant
        }
        return out
    }

    init(_ message: Pbvalueset_ValueSet) {
        var entries: [String: Value] = [:]
        for (key, variant) in message.entries {
            switch variant.valueType {
            case .int32: entries[key] = .int32(variant.int32Value)
            case .int64: entries[key] = .int64(variant.int64Value)
            case .uint32: entries[key] = .uint32(variant.uint32Value)
            case .double: entries[key] = .double(variant.doubleValue)
            case .bool: entries[key] = .bool(variant.boolValue)
            case .string: entries[key] = .string(variant.stringValue)
            case .int32Array: entries[key] = .int32Array(variant.int32Array)
            case .int64Array: entries[key] = .int64Array(variant.int64Array)
            case .stringArray: entries[key] = .stringArray(variant.stringArray)
            case .uint8Array: entries[key] = .bytes(variant.uint8Array)
            case .boolArray: entries[key] = .boolArray(variant.boolArray)
            case .object: entries[key] = .object(ValueSet(variant.objectValue))
            default: entries[key] = .other(variant)
            }
        }
        self.entries = entries
    }
}

/// Result codes carried as `result` in APP responses. Both clients use the same numbering.
public enum ScenarioResult: Int, Sendable {
    case success = 0, failure = 1, unknownType = 2, incompatibleVersions = 3, userAccepted = 4, userDenied = 5
    case userPermanentlyDenied = 6, needsPermission = 7, meteredConnection = 8, needsInitialPermission = 9
    case canceledDisconnected = 10, canceledCoalesced = 11, meteredConnectionSyncDisabled = 12, allFeaturesDisabled = 13
    case invalidRequest = 14, databaseOperationFailed = 15, featureFlagDisabled = 16, deviceResolutionFailed = 17
    case deviceNotSupported = 18, userSessionInactive = 19, appLaunched = 20, twoPhoneModeSyncDisabled = 21
    case userRevokedTrust = 22, nonDefaultUserProfile = 23

    /// Phone Link treats these as a finished request.
    public var countsAsSuccess: Bool {
        self == .success || self == .canceledDisconnected || self == .canceledCoalesced || self == .featureFlagDisabled
    }
}
