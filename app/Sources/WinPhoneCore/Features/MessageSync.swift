import Foundation

/// A picture, video or other file inside a picture message (MMS).
public struct MessageAttachment: Equatable, Sendable, Identifiable, Codable {
    /// Android's part ID, by which the bytes are asked for.
    public var id: Int64
    public var contentType: String
    public var name: String
    /// Size of the file on the phone, in bytes.
    public var size: Int64
    /// A small JPEG of an image attachment, kept once its bytes were seen.
    public var preview: Data?

    public init(id: Int64, contentType: String, name: String = "", size: Int64 = 0, preview: Data? = nil) {
        self.id = id
        self.contentType = contentType
        self.name = name
        self.size = size
        self.preview = preview
    }

    public var isImage: Bool { contentType.lowercased().hasPrefix("image/") }

    /// A file name to save under: the phone's when it has one, else one made from the type.
    public var fileName: String {
        if !name.isEmpty { return name }
        let subtype = contentType.split(separator: "/").last.map(String.init)?.lowercased() ?? "bin"
        return "attachment-\(id).\(subtype == "jpeg" ? "jpg" : subtype)"
    }
}

/// A file to send with a message; any makes it a picture message (MMS).
public struct OutgoingAttachment: Equatable, Sendable {
    public var name: String
    public var contentType: String
    public var data: Data

    public init(name: String, contentType: String, data: Data) {
        self.name = name
        self.contentType = contentType
        self.data = data
    }
}

/// A text message on the phone.
public struct PhoneMessage: Equatable, Sendable, Identifiable, Codable {
    public enum Kind: String, Sendable, Codable { case sms, mms }

    public var kind: Kind
    /// The phone's row ID. SMS and MMS number separately, so identity is kind plus ID.
    public var messageId: Int64
    public var threadId: Int64
    public var date: Date
    public var body: String
    /// Received by the phone, as opposed to sent from it.
    public var isIncoming: Bool
    public var isRead: Bool
    /// The other party: the sender of a received message, the recipient of a sent one.
    public var address: String
    public var subscriptionId: Int64
    /// Number of MMS parts that are not text, such as pictures.
    public var attachmentCount = 0
    /// The non-text parts, when the phone has described them. Optional so that a cache
    /// written before attachments were kept still reads.
    public var parts: [MessageAttachment]?
    public var attachments: [MessageAttachment] { parts ?? [] }

    public init(kind: Kind, messageId: Int64, threadId: Int64, date: Date, body: String, isIncoming: Bool, isRead: Bool, address: String,
                subscriptionId: Int64, attachmentCount: Int = 0) {
        self.kind = kind
        self.messageId = messageId
        self.threadId = threadId
        self.date = date
        self.body = body
        self.isIncoming = isIncoming
        self.isRead = isRead
        self.address = address
        self.subscriptionId = subscriptionId
        self.attachmentCount = attachmentCount
    }

    public var id: String { "\(kind.rawValue)-\(messageId)" }
}

/// A SIM subscription on the phone.
public struct PhoneSubscription: Equatable, Sendable, Identifiable, Codable {
    public var id: Int64
    public var name: String
    public var number: String
    public var slot: Int
    public var isDefaultForSMS: Bool
}

/// A message this computer asked the phone to send, until the phone confirms it.
public struct PendingMessage: Equatable, Sendable, Identifiable {
    public enum State: Equatable, Sendable { case sending, failed(reason: Int?) }

    /// The number the phone echoes in its acknowledgements.
    public var id: Int64
    public var threadId: Int64?
    public var recipients: [String]
    public var body: String
    public var date: Date
    public var state: State
    /// Files going out with the text.
    public var attachmentCount = 0

    public init(id: Int64, threadId: Int64?, recipients: [String], body: String, date: Date, state: State, attachmentCount: Int = 0) {
        self.attachmentCount = attachmentCount
        self.id = id
        self.threadId = threadId
        self.recipients = recipients
        self.body = body
        self.date = date
        self.state = state
    }
}

/// A thread with everything needed to show it. The phone sends only the thread's ID and
/// participants; the last message, unread state and order are worked out here.
public struct Conversation: Equatable, Sendable, Identifiable {
    public var id: Int64
    /// Addresses of the other participants, as stored on the phone.
    public var participants: [String]
    /// Oldest first.
    public var messages: [PhoneMessage]
    public var pending: [PendingMessage]

    public init(id: Int64, participants: [String], messages: [PhoneMessage], pending: [PendingMessage]) {
        self.id = id
        self.participants = participants
        self.messages = messages
        self.pending = pending
    }

    public var lastMessage: PhoneMessage? { messages.last }
    public var lastActivity: Date { max(messages.last?.date ?? .distantPast, pending.last?.date ?? .distantPast) }
    public var unreadCount: Int { messages.filter { $0.isIncoming && !$0.isRead }.count }
    public var title: String {
        let names = participants.isEmpty ? Array(Set(messages.map(\.address).filter { !$0.isEmpty })).sorted() : participants
        return names.isEmpty ? "Unknown" : names.joined(separator: ", ")
    }
}

/// Text message sync with a phone.
///
/// The phone pushes everything on `/legacy/phonecontent` with content type `messaging`: on a
/// first sync a list of every ID, which this client answers by naming the items it wants, then
/// batches of parallel arrays for SMS, MMS, threads, addresses and SIM cards. Later changes
/// arrive as further batches. Sending goes to `/chat/v1`.
public actor MessageSync {
    public static let route = "/chat/v1"
    public static let contentType = "messaging"
    /// The content types whose sequence numbers this client tracks.
    public static let sequenceKeys = ["sms", "mms", "conversation", "subscription"]

    public enum SendError: Error, Equatable {
        case needsPermission
        /// The phone could not send. `reason` is its failure code, such as 2 for "no SIM".
        case failed(reason: Int?)
    }

    public enum AttachmentError: Error, Equatable {
        /// The phone answered without the file.
        case unavailable
    }

    private var messenger: PeerMessenger?
    private let sender: AppSender
    private let cache: BlobCache?
    private var saving: Task<Void, Never>?
    private var sms: [Int64: PhoneMessage] = [:]
    private var mms: [Int64: PhoneMessage] = [:]
    /// A date as the phone counts it. Dates come from the phone, so an absurd one must not trap.
    static func milliseconds(_ date: Date) -> Int64 {
        let value = (date.timeIntervalSince1970 * 1000).rounded()
        return Int64(exactly: value) ?? (value > 0 ? .max : 0)
    }

    /// Thread ID to the space-separated address IDs of its participants.
    private var threads: [Int64: String] = [:]
    private var addresses: [String: String] = [:]
    private var subscriptionsById: [Int64: PhoneSubscription] = [:]
    private var pending: [PendingMessage] = []
    /// The phone repeats its last 32 acknowledgements in every push, also ones from earlier
    /// runs, so the numbers must not start over at each launch.
    private var nextSendId = Int64(Date().timeIntervalSince1970 * 1000)
    /// Sends the phone has taken on; they are settled by an acknowledgement, not by the request.
    private var accepted: Set<Int64> = []
    /// Attachment bytes seen in this run, by part ID. Not kept between launches; the small
    /// previews are.
    private var attachmentBytes: [Int64: Data] = [:]
    /// Largest total of attachment bytes held in memory before the oldest are let go.
    static let attachmentMemoryLimit = 64 * 1024 * 1024
    private var attachmentOrder: [Int64] = []
    /// The phone's sequence numbers as of the last completed sync; -1 means nothing held.
    public private(set) var sequenceNumbers: [String: Int64] = Dictionary(uniqueKeysWithValues: MessageSync.sequenceKeys.map { ($0, -1) })
    private let continuation: AsyncStream<[Conversation]>.Continuation

    /// The conversations, most recent first, each time anything changes.
    public nonisolated let updates: AsyncStream<[Conversation]>

    /// Everything held, in the form kept between launches.
    struct Snapshot: Codable, Equatable {
        var sequenceNumbers: [String: Int64]
        var sms: [PhoneMessage]
        var mms: [PhoneMessage]
        var threads: [Int64: String]
        var addresses: [String: String]
        var subscriptions: [PhoneSubscription]
    }

    /// - Parameters:
    ///   - messenger: the connection to the phone, or nil until one is attached.
    ///   - cache: where to keep the messages between launches. With it the phone is asked
    ///     only for what changed, instead of listing every thread it knows at each start.
    public init(messenger: PeerMessenger? = nil, sender: AppSender, cache: BlobCache? = nil) {
        self.messenger = messenger
        self.sender = sender
        self.cache = cache
        (updates, continuation) = AsyncStream.makeStream(of: [Conversation].self, bufferingPolicy: .bufferingNewest(4))
        if let data = cache?.load(), let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            sequenceNumbers = snapshot.sequenceNumbers
            sms = Dictionary(snapshot.sms.map { ($0.messageId, $0) }, uniquingKeysWith: { $1 })
            mms = Dictionary(snapshot.mms.map { ($0.messageId, $0) }, uniquingKeysWith: { $1 })
            threads = snapshot.threads
            addresses = snapshot.addresses
            subscriptionsById = Dictionary(snapshot.subscriptions.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        }
    }

    /// How long a send the phone accepted may wait for its acknowledgement. The phone keeps
    /// acknowledgements in memory only, so one can be lost when its app restarts; the real
    /// message has long arrived through the sync by then.
    static let acknowledgementWait: TimeInterval = 10 * 60

    private func dropStaleAccepted() {
        let cutoff = Date().addingTimeInterval(-MessageSync.acknowledgementWait)
        let stale = pending.filter { accepted.contains($0.id) && $0.date < cutoff }.map(\.id)
        guard !stale.isEmpty else { return }
        pending.removeAll { stale.contains($0.id) }
        accepted.subtract(stale)
    }

    /// Uses a new connection to the phone. The messages held are kept.
    public func attach(_ messenger: PeerMessenger) {
        self.messenger = messenger
        dropStaleAccepted()
        // A request still unanswered belonged to the old connection and never will be. One
        // the phone accepted is on its way and stays "sending" until it is acknowledged.
        for index in pending.indices where pending[index].state == .sending && !accepted.contains(pending[index].id) {
            pending[index].state = .failed(reason: nil)
        }
        publish()
    }

    var snapshot: Snapshot {
        Snapshot(sequenceNumbers: sequenceNumbers, sms: Array(sms.values), mms: Array(mms.values), threads: threads,
                 addresses: addresses, subscriptions: Array(subscriptionsById.values))
    }

    /// Writes the cache shortly after the last change, so a burst of batches is one write.
    private func scheduleSave() {
        guard let cache, saving == nil else { return }
        saving = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            await self?.saveNow(to: cache)
        }
    }

    private func saveNow(to cache: BlobCache) {
        saving = nil
        if let data = try? JSONEncoder().encode(snapshot) { cache.save(data) }
    }

    /// Forgets everything, for a sign-out or when the phone's numbering started over.
    public func reset() {
        sms = [:]; mms = [:]; threads = [:]; addresses = [:]; subscriptionsById = [:]; pending = []
        attachmentBytes = [:]; attachmentOrder = []
        sequenceNumbers = Dictionary(uniqueKeysWithValues: MessageSync.sequenceKeys.map { ($0, -1) })
        cache?.clear()
        publish()
    }

    /// Compares the numbers held with the phone's current ones from the handshake reply.
    /// A phone number below ours means its message store was reset, so ours is discarded and
    /// the next handshake asks for everything.
    /// - Returns: true when the state was discarded.
    @discardableResult
    public func reconcile(phoneNumbers: [String: Int64], sent: [String: Int64]? = nil) -> Bool {
        // Compared with what the phone was told, not with what a push may have added since.
        for key in MessageSync.sequenceKeys {
            if let ours = (sent ?? sequenceNumbers)[key], ours >= 0, let theirs = phoneNumbers[key], theirs < ours {
                reset()
                return true
            }
        }
        return false
    }

    // MARK: State

    public var subscriptions: [PhoneSubscription] { subscriptionsById.values.sorted { $0.slot < $1.slot } }

    /// Threads that have at least one message or a message being sent, most recent first.
    public var conversations: [Conversation] {
        var grouped: [Int64: [PhoneMessage]] = [:]
        for message in sms.values { grouped[message.threadId, default: []].append(message) }
        for message in mms.values { grouped[message.threadId, default: []].append(message) }
        var result: [Conversation] = []
        var threadIds = Set(grouped.keys)
        for item in pending { if let thread = item.threadId { threadIds.insert(thread) } }
        for thread in threadIds {
            let participants = (threads[thread] ?? "").split(separator: " ").compactMap { addresses[String($0)] }
            let messages = (grouped[thread] ?? []).sorted { ($0.date, $0.messageId) < ($1.date, $1.messageId) }
            result.append(Conversation(id: thread, participants: participants, messages: messages,
                                       pending: pending.filter { $0.threadId == thread }))
        }
        // Messages to a new recipient have no thread yet; show each as its own conversation.
        for item in pending where item.threadId == nil {
            result.append(Conversation(id: -item.id, participants: item.recipients, messages: [], pending: [item]))
        }
        return result.sorted { ($0.lastActivity, $0.id) > ($1.lastActivity, $1.id) }
    }

    private func publish() { continuation.yield(conversations) }

    /// Sends the current list again, for a new listener.
    public func republish() { publish() }

    // MARK: Pushes from the phone

    /// Applies a `messaging` push and returns the reply value set.
    public func apply(_ values: ValueSet) -> ValueSet {
        if values.entries["metadata"] != nil { return answerMetadata(values) }
        if let object = values.object("subscriptions") { applySubscriptions(object) }
        if let object = values.object("canonicalAddresses") { applyAddresses(object) }
        if let object = values.object("conversations") { applyThreads(object) }
        if let object = values.object("smsMessages") { applySMS(object) }
        let parts = values.object("mmsParts").map(readParts)
        if let object = values.object("mmsMessages") { applyMMS(object, texts: parts?.texts ?? [:]) }
        // After the messages, so that parts arriving with their message find it; a batch of
        // parts alone is the answer to a request for attachment bytes.
        if let parts { merge(parts.attachments) }
        if let acknowledged = values.object("acks")?.int64s("ids"), !acknowledged.isEmpty {
            // The phone repeats old acknowledgements in every push; unknown ones are no-ops.
            // An acknowledged message was sent, whatever this side thought had become of it.
            pending.removeAll { acknowledged.contains($0.id) }
            accepted.subtract(acknowledged)
        }
        dropStaleAccepted()
        // Numbers are stored from the batch that carries them, the last of a sync.
        if let numbers = values.object("sequenceNumbers") { store(numbers) }
        publish()
        scheduleSave()
        return ValueSet(["result": .int32(0)])
    }

    private func store(_ numbers: ValueSet) {
        for key in MessageSync.sequenceKeys {
            if let number = numbers.int(key) { sequenceNumbers[key] = Int64(number) }
        }
    }

    /// First round of a full sync: every ID with a checksum. The answer lists what is wanted;
    /// with nothing wanted the phone treats this client as up to date.
    private func answerMetadata(_ values: ValueSet) -> ValueSet {
        func wanted<T>(_ idsKey: String, _ checksumsKey: String, in store: inout [Int64: T], checksum: (T) -> Int64?) -> [Int64] {
            let ids = values.int64s(idsKey) ?? [], checksums = values.int64s(checksumsKey) ?? []
            let listed = Set(ids)
            // The list is complete: anything not in it no longer exists on the phone.
            store = store.filter { listed.contains($0.key) }
            var result: [Int64] = []
            for (index, id) in ids.enumerated() {
                guard let existing = store[id] else { result.append(id); continue }
                if let known = checksum(existing), index < checksums.count, known != checksums[index] { result.append(id) }
            }
            return result
        }
        // For a message the phone's checksum is simply its read flag.
        let smsIds = wanted("messagingSmsIds", "messagingSmsChecksums", in: &sms) { $0.isRead ? 1 : 0 }
        // A picture message held from before its parts were kept is asked for again.
        let mmsIds = wanted("messagingMmsIds", "messagingMmsChecksums", in: &mms) { $0.attachmentCount > 0 && $0.parts == nil ? -1 : ($0.isRead ? 1 : 0) }
        // Threads are never asked for. The phone lists every thread it has ever known, mostly
        // without messages in the synced period, and building thousands of them keeps it busy
        // for minutes, during which it answers nothing else. It adds the thread of every
        // message it sends anyway, with the participants' addresses.
        let listedThreads = Set(values.int64s("messagingConversationIds") ?? [])
        threads = threads.filter { listedThreads.contains($0.key) }
        let threadIds: [Int64] = []
        // SIM checksums are opaque, so those are asked for again each time; there are one or two.
        let subscriptionIds = values.int64s("messagingSubscriptionIds") ?? []
        let listedSubscriptions = Set(subscriptionIds)
        subscriptionsById = subscriptionsById.filter { listedSubscriptions.contains($0.key) }

        let total = smsIds.count + mmsIds.count + threadIds.count + subscriptionIds.count
        if total == 0, let numbers = values.object("sequenceNumbers") { store(numbers) }
        publish()
        scheduleSave()
        var reply = ValueSet([
            "result": .int32(0),
            "contentType": .string(MessageSync.contentType),
            "contractVersion": .double(ValueSet.contractVersion),
            "itemCount": .int32(Int32(total)),
            "messagingSmsIds": .int64Array(smsIds),
            "messagingMmsIds": .int64Array(mmsIds),
            "messagingMmsPartIds": .int64Array([]),
            "messagingConversationIds": .int64Array(threadIds),
            "messagingSubscriptionIds": .int64Array(subscriptionIds),
        ])
        if let correlation = values.string("correlationVector") { reply["correlationVector"] = .string(correlation) }
        return reply
    }

    private func applySubscriptions(_ object: ValueSet) {
        let ids = object.int64s("ids") ?? [], actions = object.int32s("actions") ?? []
        let names = object.strings("names") ?? [], numbers = object.strings("numbers") ?? []
        let slots = object.int64s("simSlotIndices") ?? [], defaults = object.bools("isDefaultSmsSubscriptions") ?? []
        for (index, id) in ids.enumerated() {
            if index < actions.count, actions[index] == 2 { subscriptionsById.removeValue(forKey: id); continue }
            subscriptionsById[id] = PhoneSubscription(id: id, name: index < names.count ? names[index] : "",
                                                      number: index < numbers.count ? numbers[index] : "",
                                                      slot: index < slots.count ? Int(slots[index]) : 0,
                                                      isDefaultForSMS: index < defaults.count ? defaults[index] : false)
        }
    }

    private func applyAddresses(_ object: ValueSet) {
        let ids = object.strings("ids") ?? [], values = object.strings("addresses") ?? []
        for (id, address) in zip(ids, values) { addresses[id] = address }
    }

    private func applyThreads(_ object: ValueSet) {
        let ids = object.int64s("ids") ?? [], actions = object.int32s("actions") ?? [], recipients = object.strings("recipientIds") ?? []
        for (index, id) in ids.enumerated() {
            if index < actions.count, actions[index] == 2 { threads.removeValue(forKey: id); continue }
            if index < recipients.count { threads[id] = recipients[index] }
        }
    }

    private func applySMS(_ object: ValueSet) {
        let ids = object.int64s("messageIds") ?? [], actions = object.int32s("actions") ?? []
        let threadIds = object.int64s("threadIds") ?? [], types = object.int32s("messageTypes") ?? [], dates = object.int64s("dates") ?? []
        let bodies = object.strings("bodies") ?? [], from = object.strings("fromAddresses") ?? [], to = object.strings("toAddresses") ?? []
        let read = object.bools("readFlags") ?? [], subscriptions = object.int64s("subscriptionIds") ?? []
        for (index, id) in ids.enumerated() {
            if index < actions.count, actions[index] == 2 { sms.removeValue(forKey: id); continue }
            guard index < threadIds.count, index < types.count, index < dates.count, index < bodies.count else { continue }
            // Mailbox 1 is the inbox; everything else synced was sent from the phone.
            let incoming = types[index] == 1
            let address = incoming ? (index < from.count ? from[index] : "") : (index < to.count ? to[index] : "")
            sms[id] = PhoneMessage(kind: .sms, messageId: id, threadId: threadIds[index],
                                   date: Date(timeIntervalSince1970: TimeInterval(dates[index]) / 1000), body: bodies[index],
                                   isIncoming: incoming, isRead: index < read.count ? read[index] : !incoming, address: address,
                                   subscriptionId: index < subscriptions.count ? subscriptions[index] : -1)
        }
    }

    /// Reads `mmsParts`: the text of each message's text parts, and its other parts as
    /// attachments. Bytes, where included, lie end to end in `contentBytes`; a size of -1
    /// means that part's bytes were left out.
    private func readParts(_ parts: ValueSet) -> (texts: [Int64: [String]], attachments: [Int64: [MessageAttachment]]) {
        var texts: [Int64: [String]] = [:], attachments: [Int64: [MessageAttachment]] = [:]
        let owners = parts.int64s("messageIds") ?? [], types = parts.strings("contentTypes") ?? [], partTexts = parts.strings("texts") ?? []
        let ids = parts.int64s("partIds") ?? [], names = parts.strings("names") ?? [], fileNames = parts.strings("fileNames") ?? []
        let sizes = parts.int64s("sizes") ?? [], included = parts.int32s("contentByteSizes") ?? []
        let blob = parts.bytes("contentBytes") ?? Data()
        var offset = blob.startIndex
        for (index, owner) in owners.enumerated() {
            // The bytes are walked in array order whatever the part is, or the offsets drift.
            var bytes: Data?
            if index < included.count, included[index] >= 0 {
                let end = offset + Int(included[index])
                if end <= blob.endIndex { bytes = Data(blob[offset..<end]) }
                offset = min(end, blob.endIndex)
            }
            let type = index < types.count ? types[index].lowercased() : ""
            if type.hasPrefix("text/plain") {
                if index < partTexts.count, !partTexts[index].isEmpty { texts[owner, default: []].append(partTexts[index]) }
                continue
            }
            if type == "application/smil" { continue }
            // Without a part ID the bytes could never be asked for; count it, nothing more.
            let id = index < ids.count ? ids[index] : -Int64(index) - 1
            var name = index < fileNames.count ? fileNames[index] : ""
            if name.isEmpty, index < names.count { name = names[index] }
            var attachment = MessageAttachment(id: id, contentType: type, name: name, size: index < sizes.count ? sizes[index] : 0)
            if let bytes, !bytes.isEmpty {
                remember(bytes, for: id)
                if attachment.isImage { attachment.preview = PhotoSync.makeThumbnail(from: bytes, maxPixelSize: 640, commonFormatsOnly: true) }
            }
            attachments[owner, default: []].append(attachment)
        }
        return (texts, attachments)
    }

    private func remember(_ bytes: Data, for partId: Int64) {
        if attachmentBytes.updateValue(bytes, forKey: partId) == nil { attachmentOrder.append(partId) }
        var total = attachmentBytes.values.reduce(0) { $0 + $1.count }
        while total > MessageSync.attachmentMemoryLimit, attachmentOrder.count > 1 {
            total -= attachmentBytes.removeValue(forKey: attachmentOrder.removeFirst())?.count ?? 0
        }
    }

    /// Files attachments with the messages they belong to. A part described again without
    /// bytes keeps the preview made earlier.
    private func merge(_ attachments: [Int64: [MessageAttachment]]) {
        for (owner, list) in attachments {
            guard var message = mms[owner] else { continue }
            var merged = message.attachments
            for attachment in list {
                if let index = merged.firstIndex(where: { $0.id == attachment.id }) {
                    var updated = attachment
                    if updated.preview == nil { updated.preview = merged[index].preview }
                    merged[index] = updated
                } else {
                    merged.append(attachment)
                }
            }
            message.parts = merged
            message.attachmentCount = merged.count
            mms[owner] = message
        }
    }

    private func applyMMS(_ object: ValueSet, texts: [Int64: [String]]) {
        let ids = object.int64s("messageIds") ?? [], actions = object.int32s("actions") ?? []
        let threadIds = object.int64s("threadIds") ?? [], boxes = object.int32s("messageBoxTypes") ?? [], dates = object.int64s("dates") ?? []
        let from = object.strings("fromAddresses") ?? [], to = object.strings("toAddresses") ?? [], subjects = object.strings("subjects") ?? []
        let read = object.bools("readFlags") ?? [], subscriptions = object.int64s("subscriptionIds") ?? []
        for (index, id) in ids.enumerated() {
            if index < actions.count, actions[index] == 2 { mms.removeValue(forKey: id); continue }
            guard index < threadIds.count, index < boxes.count, index < dates.count else { continue }
            let incoming = boxes[index] == 1
            let existingParts = mms[id]?.parts
            var body = (texts[id] ?? []).joined(separator: "\n")
            if body.isEmpty, index < subjects.count { body = subjects[index] }
            // A batch without parts for a message we already hold keeps what we had.
            if body.isEmpty, let existing = mms[id] { body = existing.body }
            let address = incoming ? (index < from.count ? from[index] : "") : (index < to.count ? to[index] : "")
            mms[id] = PhoneMessage(kind: .mms, messageId: id, threadId: threadIds[index],
                                   date: Date(timeIntervalSince1970: TimeInterval(dates[index]) / 1000), body: body,
                                   isIncoming: incoming, isRead: index < read.count ? read[index] : !incoming, address: address,
                                   subscriptionId: index < subscriptions.count ? subscriptions[index] : -1,
                                   attachmentCount: mms[id]?.attachmentCount ?? 0)
            mms[id]?.parts = existingParts
        }
    }

    // MARK: Commands

    func sendRequest(body: String, threadId: Int64?, recipients: [String], subscriptionId: Int32, id: Int64, tempId: String,
                     attachments: [OutgoingAttachment] = []) -> ValueSet {
        // A send is always marked as the user's action, as Windows does.
        var request = sender.request(contentType: MessageSync.contentType, userInitiated: true)
        request["requestType"] = .int32(2)
        request["configuration"] = .object(ConnectExchange.messagingConfiguration)
        request["tempId"] = .string(tempId)
        // Exact types matter: the phone casts `id` and `threadId` to 64 bits and `subscriptionId` to 32.
        request["id"] = .int64(id)
        // Windows leaves the key out when there is no text; a picture can go alone.
        if !body.isEmpty || attachments.isEmpty { request["body"] = .string(body) }
        if !attachments.isEmpty {
            // The files travel inside the request, end to end, with their lengths alongside.
            // Windows sends the lengths unsigned; the phone reads signed ones as well.
            request["partCount"] = .int32(Int32(attachments.count))
            request["partNames"] = .stringArray(attachments.map(\.name))
            request["partContentTypes"] = .stringArray(attachments.map(\.contentType))
            request["partByteCounts"] = .int32Array(attachments.map { Int32(clamping: $0.data.count) })
            request["partBytes"] = .bytes(attachments.reduce(into: Data()) { $0.append($1.data) })
            request["partContentIds"] = .stringArray(attachments.map { _ in "" })
        }
        request["subscriptionId"] = .int32(subscriptionId)
        if let threadId { request["threadId"] = .int64(threadId) } else { request["recipients"] = .stringArray(recipients) }
        return request
    }

    /// Sends a text. Give `threadId` to answer in an existing conversation, or `recipients`
    /// to start one. The phone decides whether it goes out as SMS or MMS. Returns once the phone
    /// has handed the message to the network, which can take a minute; the sent message then
    /// arrives through the normal sync.
    public func send(_ body: String, threadId: Int64? = nil, recipients: [String] = [], subscriptionId: Int64? = nil,
                     attachments: [OutgoingAttachment] = []) async throws {
        let id = nextSendId
        nextSendId += 1
        pending.append(PendingMessage(id: id, threadId: threadId, recipients: recipients, body: body, date: Date(), state: .sending,
                                      attachmentCount: attachments.count))
        publish()
        // Name the SIM as Windows does: the phone's default one for texts when the caller has
        // no preference, and -1 (the phone decides) only when none is known yet.
        let sim = subscriptionId ?? subscriptionsById.values.first(where: \.isDefaultForSMS)?.id ?? -1
        let request = sendRequest(body: body, threadId: threadId, recipients: recipients, subscriptionId: Int32(exactly: sim) ?? -1,
                                  id: id, tempId: UUID().uuidString.lowercased(), attachments: attachments)
        do {
            guard let messenger else { throw SendError.failed(reason: nil) }
            // A picture message is answered when the network took it, which takes longer.
            let envelope = try await messenger.appRequest(route: MessageSync.route, payload: request.serialized(),
                                                          timeout: attachments.isEmpty ? nil : .seconds(180))
            let reply = try ValueSet(serialized: envelope.payload)
            let result = reply.int("result").flatMap(ScenarioResult.init)
            if result == .needsPermission { throw SendError.needsPermission }
            guard result == .success else { throw SendError.failed(reason: reply.int("sendMessageFailureReason")) }
            accepted.insert(id)
        } catch {
            let reason: Int?
            if case SendError.failed(let code) = error { reason = code } else { reason = nil }
            if let index = pending.firstIndex(where: { $0.id == id }) { pending[index].state = .failed(reason: reason) }
            publish()
            throw error
        }
    }

    /// Tells the phone a thread has been read up to a point in time. Only phones whose
    /// messaging app supports it act on this; the others answer success and change nothing,
    /// so callers keep their own read state as well.
    public func markRead(threadId: Int64, through date: Date) async throws {
        var request = sender.request(contentType: MessageSync.contentType)
        request["requestType"] = .int32(3)
        request["configuration"] = .object(ConnectExchange.messagingConfiguration)
        request["threadId"] = .int64(threadId)
        request["timestamp"] = .int64(MessageSync.milliseconds(date))
        guard let messenger else { throw SendError.failed(reason: nil) }
        _ = try await messenger.appRequest(route: MessageSync.route, payload: request.serialized())
    }

    /// Drops a message that failed to send.
    public func discardFailed(id: Int64) {
        pending.removeAll { $0.id == id && $0.state != .sending }
        publish()
    }

    /// Whether a sync has completed since this session started.
    public var hasSynced: Bool { sequenceNumbers.values.contains { $0 >= 0 } }

    func attachmentRequest(partIds: [Int64]) -> ValueSet {
        var request = sender.request(contentType: MessageSync.contentType, userInitiated: true)
        request["requestType"] = .int32(1)
        request["configuration"] = .object(ConnectExchange.messagingConfiguration)
        request["subcontentTypes"] = .stringArray(["messagesMmsMedia"])
        request["requestedItems"] = .int32(1)
        request["messagingMmsPartIds"] = .int64Array(partIds)
        return request
    }

    func describeRequest(mmsIds: [Int64]) -> ValueSet {
        var request = sender.request(contentType: MessageSync.contentType, userInitiated: true)
        request["requestType"] = .int32(1)
        request["configuration"] = .object(ConnectExchange.messagingConfiguration)
        // The one item request Windows is known to build names this type; the ID list is read
        // by the same code as the answer to a list round.
        request["subcontentTypes"] = .stringArray(["messagesMmsMedia"])
        request["requestedItems"] = .int32(1)
        request["messagingMmsIds"] = .int64Array(mmsIds)
        return request
    }

    /// Asks the phone to send one picture message again, with the description of its parts.
    /// For a message this client holds only as "has attachments", from before parts were kept.
    public func describeAttachments(of messageId: Int64) async throws {
        guard mms[messageId] != nil else { throw AttachmentError.unavailable }
        guard let messenger else { throw SendError.failed(reason: nil) }
        let envelope = try await messenger.appRequest(route: MessageSync.route, payload: describeRequest(mmsIds: [messageId]).serialized(),
                                                      timeout: .seconds(120))
        let result = (try? ValueSet(serialized: envelope.payload))?.int("result").flatMap(ScenarioResult.init)
        if result == .needsPermission { throw SendError.needsPermission }
        guard mms[messageId]?.parts != nil else { throw AttachmentError.unavailable }
    }

    /// The bytes of one attachment: from memory when they were seen in this run, otherwise
    /// asked from the phone, which pushes them as a batch of parts before it answers.
    public func attachmentData(partId: Int64) async throws -> Data {
        if let held = attachmentBytes[partId] { return held }
        guard let messenger else { throw SendError.failed(reason: nil) }
        let envelope = try await messenger.appRequest(route: MessageSync.route, payload: attachmentRequest(partIds: [partId]).serialized(),
                                                      timeout: .seconds(120))
        let result = (try? ValueSet(serialized: envelope.payload))?.int("result").flatMap(ScenarioResult.init)
        if result == .needsPermission { throw SendError.needsPermission }
        guard let data = attachmentBytes[partId] else { throw AttachmentError.unavailable }
        return data
    }

    /// Asks the phone for a full sync. It arrives as pushes; this returns the phone's result
    /// code once the sync has finished.
    @discardableResult
    public func resync() async throws -> ScenarioResult? {
        var request = sender.request(contentType: MessageSync.contentType, userInitiated: true)
        request["configuration"] = .object(ConnectExchange.messagingConfiguration)
        request["subcontentTypes"] = .stringArray(["messages", "messagesMms", "conversations", "subscriptions"])
        // Answered only when the whole sync has gone through.
        guard let messenger else { throw SendError.failed(reason: nil) }
        let envelope = try await messenger.appRequest(route: MessageSync.route, payload: request.serialized(), timeout: .seconds(600))
        let result = (try? ValueSet(serialized: envelope.payload))?.int("result").flatMap(ScenarioResult.init)
        if result == .needsPermission { throw SendError.needsPermission }
        return result
    }

    /// What a failure code from the phone means, for the interface.
    public static func describeFailure(_ reason: Int?) -> String {
        switch reason {
        case 1: return "The phone is in airplane mode."
        case 2: return "The phone has no SIM card."
        case 3: return "The message is too long or too large to send."
        case 4, 5: return "The phone cannot send picture messages."
        case 15: return "The phone did not confirm sending in time."
        case 16: return "The phone's mobile radio is off."
        case 17: return "The phone has no mobile service."
        case 18: return "No recipient."
        default: return "The phone could not send the message."
        }
    }
}
