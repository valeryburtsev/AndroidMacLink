import Foundation

/// A contact on the phone, reduced to what is needed to put a name and a face to an address.
public struct PhoneContact: Equatable, Sendable, Identifiable, Codable {
    public var id: Int64
    public var displayName: String
    public var company: String
    /// A small JPEG, about 96 pixels, or nil.
    public var photo: Data?

    public init(id: Int64, displayName: String, company: String = "", photo: Data? = nil) {
        self.id = id
        self.displayName = displayName
        self.company = company
        self.photo = photo
    }

    /// The name to show: the display name, or the company for a contact without one.
    public var name: String { displayName.isEmpty ? company : displayName }
}

/// The phone's contacts indexed by phone number and e-mail address.
public struct ContactBook: Equatable, Sendable {
    public private(set) var contacts: [Int64: PhoneContact] = [:]
    /// Each contact's numbers as the user typed them, for choosing one to write to.
    public private(set) var numbersByContact: [Int64: [String]] = [:]
    /// Normalized address to the IDs of the contacts that have it.
    private var index: [String: [Int64]] = [:]
    /// For numbers stored with a country code: the digits after `+`, to match addresses
    /// written without one.
    private var internationalDigits: [String: [Int64]] = [:]

    public init() {}

    /// A number someone can be written to, with the contact it belongs to.
    public struct Recipient: Equatable, Sendable, Identifiable {
        public var contact: PhoneContact
        public var number: String
        public var id: String { "\(contact.id)-\(number)" }
    }

    /// Contacts whose name or number contains the text, by name, one entry per number.
    public func recipients(matching query: String, limit: Int = 12) -> [Recipient] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        let digits = needle.filter(\.isNumber)
        var found: [Recipient] = []
        for contact in contacts.values.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
            let numbers = numbersByContact[contact.id] ?? []
            guard !numbers.isEmpty, !contact.name.isEmpty else { continue }
            let nameMatches = contact.name.lowercased().contains(needle)
            for number in numbers where nameMatches || (digits.count >= 3 && number.filter(\.isNumber).contains(digits)) {
                found.append(Recipient(contact: contact, number: number))
                if found.count == limit { return found }
            }
        }
        return found
    }

    /// - Parameters:
    ///   - numbers: numbers in the form used for matching, with their contact.
    ///   - displayNumbers: the same numbers as the user wrote them; defaults to `numbers`.
    public init(contacts: [PhoneContact], numbers: [(number: String, contactId: Int64)], emails: [(address: String, contactId: Int64)],
                displayNumbers: [(number: String, contactId: Int64)] = []) {
        self.contacts = Dictionary(contacts.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        for entry in displayNumbers.isEmpty ? numbers : displayNumbers where !entry.number.isEmpty {
            if numbersByContact[entry.contactId]?.contains(entry.number) != true { numbersByContact[entry.contactId, default: []].append(entry.number) }
        }
        for entry in numbers {
            let key = ContactBook.key(forNumber: entry.number)
            guard !key.isEmpty else { continue }
            index[key, default: []].append(entry.contactId)
            if key.hasPrefix("+") { internationalDigits[String(key.dropFirst()), default: []].append(entry.contactId) }
        }
        for entry in emails where !entry.address.isEmpty {
            index[entry.address.lowercased(), default: []].append(entry.contactId)
        }
    }

    public var isEmpty: Bool { contacts.isEmpty }

    /// A number reduced to `+` and digits, or to digits alone when it has no country code.
    /// Sender names and short codes with letters are kept as they are, lower-cased.
    public static func key(forNumber text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.contains(where: \.isLetter) { return trimmed.lowercased() }
        let digits = trimmed.filter(\.isNumber)
        guard !digits.isEmpty else { return "" }
        return trimmed.hasPrefix("+") ? "+" + digits : digits
    }

    /// The contact for a phone number, short code or e-mail address, if there is one.
    public func contact(for address: String) -> PhoneContact? {
        let key = address.contains("@") ? address.lowercased() : ContactBook.key(forNumber: address)
        guard !key.isEmpty else { return nil }
        if let found = best(index[key]) { return found }
        guard !key.hasPrefix("+"), !key.contains(where: \.isLetter) else { return nil }
        // A number written the national way, such as 082 123 4567, against a contact stored
        // with its country code, +27 82 123 4567: the whole national number must be the end of
        // the stored one, and what precedes it can only be a country code of one to three digits.
        let national = String(key.drop { $0 == "0" })
        guard national.count >= 7 else { return nil }
        var candidates: [Int64] = []
        for (digits, ids) in internationalDigits where digits.hasSuffix(national) && (1...3).contains(digits.count - national.count) {
            candidates += ids
        }
        return best(candidates)
    }

    /// Several contacts can share a number: the first with a name wins, as in Phone Link.
    private func best(_ ids: [Int64]?) -> PhoneContact? {
        let found = (ids ?? []).compactMap { contacts[$0] }
        return found.first { !$0.name.isEmpty } ?? found.first
    }

    /// The name for an address, or nil when no contact has it.
    public func name(for address: String) -> String? {
        guard let contact = contact(for: address), !contact.name.isEmpty else { return nil }
        return contact.name
    }
}

/// The phone's contacts.
///
/// Same pattern as the other content: the phone pushes `contactsV2` on `/legacy/phonecontent`,
/// first a list of every row ID with a checksum in six tables, which this client answers by
/// naming what it wants, then the rows as parallel arrays. Only contacts, phone numbers and
/// e-mail addresses are asked for; postal addresses, dates and web addresses are not.
public actor ContactSync {
    public static let contentType = "contactsV2"
    /// All six must be sent in the handshake, or the phone starts a full sync every time.
    public static let sequenceKeys = ["contact", "phonenumber", "emailaddress", "postaladdress", "contactdate", "contacturl"]

    struct NumberRow: Codable, Equatable { var contactId: Int64; var number: String; var display: String; var checksum: Int64 }
    struct EmailRow: Codable, Equatable { var contactId: Int64; var address: String; var checksum: Int64 }

    struct Snapshot: Codable {
        var sequenceNumbers: [String: Int64]
        var contacts: [PhoneContact]
        var contactChecksums: [Int64: Int64]
        var numbers: [Int64: NumberRow]
        var emails: [Int64: EmailRow]
    }

    private var contacts: [Int64: PhoneContact] = [:]
    /// Checksums from the phone's list. For contacts the value in a content batch differs when
    /// the contact has a photo, so the list's value is the one to compare next time.
    private var contactChecksums: [Int64: Int64] = [:]
    private var numbers: [Int64: NumberRow] = [:]
    private var emails: [Int64: EmailRow] = [:]
    /// Checksums offered in the list currently being synced, kept until its rows arrive.
    private var offeredContactChecksums: [Int64: Int64] = [:]
    public private(set) var sequenceNumbers: [String: Int64] = Dictionary(uniqueKeysWithValues: ContactSync.sequenceKeys.map { ($0, -1) })
    private let cache: BlobCache?
    private var saving: Task<Void, Never>?
    private let continuation: AsyncStream<ContactBook>.Continuation

    /// The address book each time it changes.
    public nonisolated let updates: AsyncStream<ContactBook>

    public init(cache: BlobCache? = nil) {
        self.cache = cache
        (updates, continuation) = AsyncStream.makeStream(of: ContactBook.self, bufferingPolicy: .bufferingNewest(2))
        if let data = cache?.load(), let snapshot = try? PropertyListDecoder().decode(Snapshot.self, from: data) {
            sequenceNumbers = snapshot.sequenceNumbers
            contacts = Dictionary(snapshot.contacts.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
            contactChecksums = snapshot.contactChecksums
            numbers = snapshot.numbers
            emails = snapshot.emails
        }
    }

    public var book: ContactBook {
        ContactBook(contacts: Array(contacts.values), numbers: numbers.values.map { ($0.number, $0.contactId) },
                    emails: emails.values.map { ($0.address, $0.contactId) },
                    displayNumbers: numbers.values.map { ($0.display.isEmpty ? $0.number : $0.display, $0.contactId) })
    }

    private func publish() {
        continuation.yield(book)
        scheduleSave()
    }

    /// Sends the current address book again, for a new listener.
    public func republish() { continuation.yield(book) }

    private func scheduleSave() {
        guard let cache, saving == nil else { return }
        saving = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            await self?.saveNow(to: cache)
        }
    }

    private func saveNow(to cache: BlobCache) {
        saving = nil
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let snapshot = Snapshot(sequenceNumbers: sequenceNumbers, contacts: Array(contacts.values), contactChecksums: contactChecksums,
                                numbers: numbers, emails: emails)
        if let data = try? encoder.encode(snapshot) { cache.save(data) }
    }

    /// Forgets everything, for a sign-out or when the phone's numbering started over.
    public func reset() {
        contacts = [:]; contactChecksums = [:]; numbers = [:]; emails = [:]; offeredContactChecksums = [:]
        sequenceNumbers = Dictionary(uniqueKeysWithValues: ContactSync.sequenceKeys.map { ($0, -1) })
        cache?.clear()
        continuation.yield(book)
    }

    /// A phone number below ours means its store was reset: discard ours.
    @discardableResult
    public func reconcile(phoneNumbers: [String: Int64], sent: [String: Int64]? = nil) -> Bool {
        // Compared with what the phone was told, not with what a push may have added since.
        for key in ContactSync.sequenceKeys {
            if let ours = (sent ?? sequenceNumbers)[key], ours >= 0, let theirs = phoneNumbers[key], theirs < ours {
                reset()
                return true
            }
        }
        return false
    }

    private func store(_ object: ValueSet) {
        // In a batch this object also carries unrelated keys; only the six known ones count.
        for key in ContactSync.sequenceKeys {
            if let number = object.int(key) { sequenceNumbers[key] = Int64(number) }
        }
    }

    // MARK: Pushes from the phone

    /// Applies a `contactsV2` push and returns the reply value set.
    public func apply(_ values: ValueSet) -> ValueSet {
        if values.entries["metadata"] != nil { return answerMetadata(values) }
        if let object = values.object("contacts") { applyContacts(object) }
        if let object = values.object("phoneNumbers") { applyNumbers(object) }
        if let object = values.object("emailAddresses") { applyEmails(object) }
        if let object = values.object("sequenceNumbers") { store(object) }
        publish()
        return ValueSet(["result": .int32(0)])
    }

    private func answerMetadata(_ values: ValueSet) -> ValueSet {
        /// IDs that are new or whose checksum changed; rows no longer listed are dropped.
        func wanted<Row>(_ idsKey: String, _ checksumsKey: String, in rows: inout [Int64: Row], checksum: (Int64, Row) -> Int64?) -> (ids: [Int64], offered: [Int64: Int64]) {
            let ids = values.int64s(idsKey) ?? [], checksums = values.int64s(checksumsKey) ?? []
            let listed = Set(ids)
            rows = rows.filter { listed.contains($0.key) }
            var result: [Int64] = [], offered: [Int64: Int64] = [:]
            for (index, id) in ids.enumerated() {
                let sum = index < checksums.count ? checksums[index] : 0
                offered[id] = sum
                if let row = rows[id], checksum(id, row) == sum { continue }
                result.append(id)
            }
            return (result, offered)
        }
        let known = contactChecksums
        let contactResult = wanted("contactIds", "contactChecksums", in: &contacts) { id, _ in known[id] }
        offeredContactChecksums = contactResult.offered
        contactChecksums = contactChecksums.filter { contacts[$0.key] != nil }
        let numberIds = wanted("phoneNumberIds", "phoneNumberChecksums", in: &numbers) { _, row in row.checksum }.ids
        let emailIds = wanted("contactEmailAddressIds", "contactEmailAddressChecksums", in: &emails) { _, row in row.checksum }.ids

        let total = contactResult.ids.count + numberIds.count + emailIds.count
        // With nothing wanted the phone treats this client as up to date with the list's numbers.
        if total == 0, let object = values.object("sequenceNumbers") { store(object) }
        publish()
        var reply = ValueSet([
            "result": .int32(0),
            "contentType": .string(ContactSync.contentType),
            "contractVersion": .double(ValueSet.contractVersion),
            "itemCount": .int32(Int32(total)),
            "contactIds": .int64Array(contactResult.ids),
            "phoneNumberIds": .int64Array(numberIds),
            "contactEmailAddressIds": .int64Array(emailIds),
            // Not used here; an empty list tells the phone to skip the table.
            "contactPostalAddressIds": .int64Array([]),
            "contactDateIds": .int64Array([]),
            "contactUrlIds": .int64Array([]),
        ])
        if let correlation = values.string("correlationVector") { reply["correlationVector"] = .string(correlation) }
        return reply
    }

    private func applyContacts(_ object: ValueSet) {
        let ids = object.int64s("contactIds") ?? [], actions = object.int32s("actions") ?? []
        let names = object.strings("displayNames") ?? [], companies = object.strings("companies") ?? []
        let checksums = object.int64s("checksums") ?? []
        let sizes = object.int64s("thumbnailSizes") ?? []
        // Photos lie end to end in index order; a mismatch means none can be trusted.
        var photos: [Data] = []
        if let blob = object.bytes("thumbnails"), sizes.count == ids.count, let pieces = ValueSet.split(blob, sizes: sizes) { photos = pieces }
        for (index, id) in ids.enumerated() {
            if index < actions.count, actions[index] == 2 {
                contacts.removeValue(forKey: id)
                contactChecksums.removeValue(forKey: id)
                continue
            }
            let photo = index < photos.count && !photos[index].isEmpty ? photos[index] : nil
            contacts[id] = PhoneContact(id: id, displayName: index < names.count ? names[index] : "",
                                        company: index < companies.count ? companies[index] : "", photo: photo)
            contactChecksums[id] = offeredContactChecksums[id] ?? (index < checksums.count ? checksums[index] : 0)
        }
    }

    private func applyNumbers(_ object: ValueSet) {
        let ids = object.int64s("phoneNumberIds") ?? [], actions = object.int32s("actions") ?? []
        let owners = object.int64s("contactIds") ?? [], values = object.strings("phoneNumbers") ?? []
        let display = object.strings("displayNumbers") ?? [], checksums = object.int64s("checksums") ?? []
        for (index, id) in ids.enumerated() {
            if index < actions.count, actions[index] == 2 { numbers.removeValue(forKey: id); continue }
            guard index < owners.count, index < values.count else { continue }
            // The normalized form is for matching; when it is missing fall back to what was typed.
            let typed = index < display.count ? display[index] : ""
            numbers[id] = NumberRow(contactId: owners[index], number: values[index].isEmpty ? typed : values[index], display: typed,
                                    checksum: index < checksums.count ? checksums[index] : 0)
        }
    }

    private func applyEmails(_ object: ValueSet) {
        let ids = object.int64s("contactEmailAddressIds") ?? [], actions = object.int32s("actions") ?? []
        let owners = object.int64s("contactIds") ?? [], values = object.strings("emailAddresses") ?? []
        let checksums = object.int64s("checksums") ?? []
        for (index, id) in ids.enumerated() {
            if index < actions.count, actions[index] == 2 { emails.removeValue(forKey: id); continue }
            guard index < owners.count, index < values.count else { continue }
            emails[id] = EmailRow(contactId: owners[index], address: values[index], checksum: index < checksums.count ? checksums[index] : 0)
        }
    }
}
