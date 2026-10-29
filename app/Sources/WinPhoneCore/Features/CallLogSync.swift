import Foundation

/// One entry of the phone's call history.
public struct PhoneCall: Equatable, Sendable, Identifiable, Codable {
    public enum Kind: Equatable, Sendable {
        case incoming, outgoing, missed, declined, blocked, unknown
    }

    /// Android's row ID in the call log.
    public var id: Int64
    /// As dialled or as the network presented it; empty for a withheld number.
    public var number: String
    public var date: Date
    /// Seconds talked; 0 for a call that was not connected.
    public var duration: Int64
    /// Android's call type: 1 incoming, 2 outgoing, 3 missed, 4 voicemail, 5 rejected,
    /// 6 blocked, 7 answered on another device.
    public var type: Int
    public var isRead: Bool
    /// The row's last-modified time on the phone, compared in the next list round.
    public var checksum: Int64

    public init(id: Int64, number: String, date: Date, duration: Int64 = 0, type: Int, isRead: Bool = true, checksum: Int64 = 0) {
        self.id = id
        self.number = number
        self.date = date
        self.duration = duration
        self.type = type
        self.isRead = isRead
        self.checksum = checksum
    }

    /// The type as Phone Link groups it.
    public var kind: Kind {
        switch type {
        case 1, 4, 7: return .incoming
        case 2: return .outgoing
        case 3: return .missed
        case 5: return .declined
        case 6: return .blocked
        default: return .unknown
        }
    }
}

/// The phone's call history of the last thirty days.
///
/// The same pattern as the other content: the phone pushes `callLogs` on
/// `/legacy/phonecontent`, first every row ID with its last-modified time, which this client
/// answers with the IDs it lacks, then the rows as parallel arrays in batches of fifty. Later
/// changes arrive as batches with an action per row. The phone only does any of this while the
/// handshake's `CallLogs` switch is on, which is one setting for the whole phone.
///
/// Nothing here has been seen on the wire: Windows had the feature off in every capture. The
/// messages follow both programs' code (`protocol/specs/calls.md`).
public actor CallLogSync {
    public static let contentType = "callLogs"
    public static let sequenceKey = "call_logs"
    public static let refreshRoute = "/calling"
    public static let dialRoute = "/calling/dial"

    public enum CallError: Error, Equatable {
        case notConnected
        /// The phone has not been allowed to read the call log.
        case needsPermission
        /// The phone did not answer in time.
        case noAnswer
        case failed(Int?)
    }

    struct Snapshot: Codable {
        var sequenceNumber: Int64
        var calls: [PhoneCall]
    }

    private var calls: [Int64: PhoneCall] = [:]
    public private(set) var sequenceNumber: Int64 = -1
    /// The number announced with the list, kept once the rows asked for have arrived.
    private var pendingSequenceNumber: Int64?
    private var messenger: PeerMessenger?
    private let sender: AppSender
    private let cache: BlobCache?
    private var saving: Task<Void, Never>?
    private let continuation: AsyncStream<[PhoneCall]>.Continuation

    /// The calls, newest first, each time the list changes.
    public nonisolated let updates: AsyncStream<[PhoneCall]>

    public init(sender: AppSender, cache: BlobCache? = nil) {
        self.sender = sender
        self.cache = cache
        (updates, continuation) = AsyncStream.makeStream(of: [PhoneCall].self, bufferingPolicy: .bufferingNewest(2))
        if let data = cache?.load(), let snapshot = try? PropertyListDecoder().decode(Snapshot.self, from: data) {
            sequenceNumber = snapshot.sequenceNumber
            calls = Dictionary(snapshot.calls.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        }
    }

    public func attach(_ messenger: PeerMessenger) { self.messenger = messenger }

    /// Newest first. Blocked calls are left out, as Phone Link leaves them out.
    public var list: [PhoneCall] {
        calls.values.filter { $0.kind != .blocked }.sorted { ($0.date, $0.id) > ($1.date, $1.id) }
    }

    private func publish() {
        continuation.yield(list)
        guard let cache, saving == nil else { return }
        saving = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            await self?.saveNow(to: cache)
        }
    }

    public func republish() { continuation.yield(list) }

    private func saveNow(to cache: BlobCache) {
        saving = nil
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        if let data = try? encoder.encode(Snapshot(sequenceNumber: sequenceNumber, calls: Array(calls.values))) { cache.save(data) }
    }

    /// Forgets everything: at sign-out, when the feature is switched off, or when the phone's
    /// numbering started over.
    public func reset() {
        calls = [:]
        sequenceNumber = -1
        pendingSequenceNumber = nil
        cache?.clear()
        continuation.yield([])
    }

    /// A phone number below the one it was told means its history was rebuilt: discard ours.
    @discardableResult
    public func reconcile(phoneNumber: Int64?, sent: Int64? = nil) -> Bool {
        let ours = sent ?? sequenceNumber
        guard let phoneNumber, ours >= 0, phoneNumber < ours else { return false }
        reset()
        return true
    }

    // MARK: Pushes from the phone

    /// Applies a `callLogs` push and returns the reply value set.
    public func apply(_ values: ValueSet) -> ValueSet {
        if values.entries["metadata"] != nil { return answerMetadata(values) }
        merge(values)
        // The last batch of a sync carries the number; a row asked for may never come, so
        // completion is this number and not a count.
        if let number = values.int("sequenceNumber") {
            sequenceNumber = Int64(number)
            pendingSequenceNumber = nil
        }
        publish()
        return ValueSet(["result": .int32(0)])
    }

    private func answerMetadata(_ values: ValueSet) -> ValueSet {
        let ids = values.int64s("callLogsIds") ?? [], checksums = values.int64s("callLogsLastUpdatedTimes") ?? []
        // The list is every call of the last thirty days: one not in it is gone.
        let listed = Set(ids)
        calls = calls.filter { listed.contains($0.key) }
        var wanted: [Int64] = []
        for (index, id) in ids.enumerated() {
            let checksum = index < checksums.count ? checksums[index] : 0
            if let call = calls[id], call.checksum == checksum { continue }
            wanted.append(id)
        }
        let announced = values.int("sequenceNumber").map(Int64.init)
        if wanted.isEmpty {
            // Nothing to fetch: the phone records this client as up to date at once.
            if let announced { sequenceNumber = announced }
            pendingSequenceNumber = nil
        } else {
            pendingSequenceNumber = announced
        }
        publish()
        var reply = ValueSet([
            "result": .int32(0),
            "contentType": .string(CallLogSync.contentType),
            "contractVersion": .double(ValueSet.contractVersion),
            // Must be an Int32, and the IDs an Int64 array, also when empty.
            "itemCount": .int32(Int32(clamping: wanted.count)),
            "callLogsIds": .int64Array(wanted),
        ])
        if let correlation = values.string("correlationVector") { reply["correlationVector"] = .string(correlation) }
        return reply
    }

    /// Merges a batch of rows. Applied in array order; a removed row comes with its ID only.
    private func merge(_ values: ValueSet) {
        let ids = values.int64s("callLogsIds") ?? [], actions = values.int32s("actions") ?? []
        let numbers = values.strings("callLogsPhoneNumbers") ?? [], dates = values.int64s("callLogsDate") ?? []
        let durations = values.int64s("callLogsDuration") ?? [], types = values.int32s("callLogsType") ?? []
        let read = values.bools("callLogsRead") ?? [], checksums = values.int64s("callLogsLastUpdatedTimes") ?? []
        for (index, id) in ids.enumerated() {
            if index < actions.count, actions[index] == 2 { calls.removeValue(forKey: id); continue }
            guard index < dates.count, index < types.count else { continue }
            calls[id] = PhoneCall(id: id, number: index < numbers.count ? numbers[index] : "",
                                  date: Date(timeIntervalSince1970: TimeInterval(dates[index]) / 1000),
                                  duration: index < durations.count ? max(0, durations[index]) : 0, type: Int(types[index]),
                                  isRead: index < read.count ? read[index] : true, checksum: index < checksums.count ? checksums[index] : 0)
        }
    }

    // MARK: Requests

    func refreshRequest() -> ValueSet {
        sender.request(contentType: CallLogSync.contentType, userInitiated: true)
    }

    /// Asks the phone for its whole call history again. This also switches the feature on
    /// for the phone, should another computer have switched it off. The list arrives as
    /// pushes; the phone answers once the sync has finished.
    public func refresh() async throws {
        guard let messenger else { throw CallError.notConnected }
        let envelope = try await messenger.appRequest(route: CallLogSync.refreshRoute, payload: refreshRequest().serialized(), timeout: .seconds(120))
        try CallLogSync.check(envelope)
    }

    func dialRequest(number: String) -> ValueSet {
        var request = sender.request(contentType: "dialOnPhone", userInitiated: true)
        // The phone puts this after "tel:" as it stands, where a "#" would cut it short.
        request["phoneNumber"] = .string(number.replacingOccurrences(of: "#", with: "%23"))
        request["subcontentTypes"] = .stringArray(["dialOnPhone"])
        request["itemCount"] = .int32(1)
        return request
    }

    /// Opens the phone's dialer with a number filled in. It does not place the call: the
    /// user presses the call button on the phone. Success only means the phone was asked.
    public func dial(_ number: String) async throws {
        guard let messenger else { throw CallError.notConnected }
        // Answered at once or not at all, and the user is waiting to pick up the phone.
        let envelope: PlatformEnvelope
        do {
            envelope = try await messenger.appRequest(route: CallLogSync.dialRoute, payload: dialRequest(number: number).serialized(), timeout: .seconds(15))
        } catch PeerMessenger.MessagingError.timedOut {
            throw CallError.noAnswer
        }
        try CallLogSync.check(envelope)
    }

    private static func check(_ envelope: PlatformEnvelope) throws {
        let code = (try? ValueSet(serialized: envelope.payload))?.int("result")
        let result = code.flatMap(ScenarioResult.init)
        if result == .needsPermission { throw CallError.needsPermission }
        guard let result, result.countsAsSuccess else { throw CallError.failed(code) }
    }
}
