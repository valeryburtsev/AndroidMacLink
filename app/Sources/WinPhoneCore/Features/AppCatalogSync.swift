import Foundation

/// An app installed on the phone.
public struct PhoneApp: Equatable, Sendable, Identifiable, Codable {
    /// The phone's row ID. Random, so it says nothing about the app.
    public var id: Int64
    public var packageName: String
    public var name: String
    public var version: String
    /// The row's last-updated time on the phone; changes when the app, its label or icon does.
    public var checksum: Int64
    /// A PNG at the icon's own size, or nil.
    public var icon: Data?

    public init(id: Int64, packageName: String, name: String, version: String = "", checksum: Int64 = 0, icon: Data? = nil) {
        self.id = id
        self.packageName = packageName
        self.name = name
        self.version = version
        self.checksum = checksum
        self.icon = icon
    }
}

/// The phone's list of apps with their icons, used to show an icon next to each notification.
///
/// Same pattern as the other content: the phone pushes `phoneApps` on `/legacy/phonecontent`,
/// first every row ID with a checksum, which this client answers with the IDs it lacks, then the
/// rows as parallel arrays with the icons laid end to end. The first sync makes the phone render
/// every icon, about ten seconds for a hundred apps; everything is cached, so later only apps
/// that changed are sent.
public actor AppCatalogSync {
    public static let contentType = "phoneApps"
    /// Both must be sent in the handshake, or the phone offers the whole list at every connect.
    public static let sequenceKeys = ["phoneApps", "recentApps"]

    struct Snapshot: Codable {
        var sequenceNumbers: [String: Int64]
        var apps: [PhoneApp]
    }

    private var apps: [Int64: PhoneApp] = [:]
    public private(set) var sequenceNumbers: [String: Int64] = ["phoneApps": -1, "recentApps": -1]
    private let cache: BlobCache?
    private var saving: Task<Void, Never>?
    private let continuation: AsyncStream<[String: PhoneApp]>.Continuation

    /// The apps by package name, each time the list changes.
    public nonisolated let updates: AsyncStream<[String: PhoneApp]>

    public init(cache: BlobCache? = nil) {
        self.cache = cache
        (updates, continuation) = AsyncStream.makeStream(of: [String: PhoneApp].self, bufferingPolicy: .bufferingNewest(2))
        if let data = cache?.load(), let snapshot = try? PropertyListDecoder().decode(Snapshot.self, from: data) {
            sequenceNumbers = snapshot.sequenceNumbers
            apps = Dictionary(snapshot.apps.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        }
    }

    /// The apps by package name.
    public var byPackage: [String: PhoneApp] {
        Dictionary(apps.values.filter { !$0.packageName.isEmpty }.map { ($0.packageName, $0) }, uniquingKeysWith: { $1 })
    }

    private func publish() {
        continuation.yield(byPackage)
        guard let cache, saving == nil else { return }
        saving = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            await self?.saveNow(to: cache)
        }
    }

    /// Sends the current list again, for a new listener.
    public func republish() { continuation.yield(byPackage) }

    private func saveNow(to cache: BlobCache) {
        saving = nil
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        if let data = try? encoder.encode(Snapshot(sequenceNumbers: sequenceNumbers, apps: Array(apps.values))) { cache.save(data) }
    }

    /// Forgets everything, for a sign-out or when the phone's numbering started over.
    public func reset() {
        apps = [:]
        sequenceNumbers = ["phoneApps": -1, "recentApps": -1]
        cache?.clear()
        continuation.yield([:])
    }

    /// A phone number below ours means its table was rebuilt with new IDs: discard ours.
    @discardableResult
    public func reconcile(phoneNumbers: [String: Int64], sent: [String: Int64]? = nil) -> Bool {
        if let ours = (sent ?? sequenceNumbers)["phoneApps"], ours >= 0, let theirs = phoneNumbers["phoneApps"], theirs < ours {
            reset()
            return true
        }
        return false
    }

    // MARK: Pushes from the phone

    /// Applies a `phoneApps` push and returns the reply value set.
    public func apply(_ values: ValueSet) -> ValueSet {
        if values.entries["metadata"] != nil { return answerMetadata(values) }
        // A message with only the recently used apps: nothing to keep but its number.
        if let recent = values.int("recentAppsSequenceNumber") { sequenceNumbers["recentApps"] = Int64(recent) }
        if values.int64s("phoneAppsIds") != nil {
            merge(values)
            if let number = values.int("sequenceNumber") { sequenceNumbers["phoneApps"] = Int64(number) }
        }
        publish()
        return ValueSet(["result": .int32(0)])
    }

    private func answerMetadata(_ values: ValueSet) -> ValueSet {
        let ids = values.int64s("phoneAppsIds") ?? [], checksums = values.int64s("checksums") ?? []
        // The list is complete: an app not in it was removed from the phone.
        let listed = Set(ids)
        apps = apps.filter { listed.contains($0.key) }
        var wanted: [Int64] = []
        for (index, id) in ids.enumerated() {
            let checksum = index < checksums.count ? checksums[index] : 0
            if let app = apps[id], app.checksum == checksum, app.icon != nil { continue }
            wanted.append(id)
        }
        // The recently used apps are not fetched, but holding their number keeps the phone
        // from starting a full sync at every connect.
        if let recent = values.int("recentAppsSequenceNumber") { sequenceNumbers["recentApps"] = Int64(recent) }
        if wanted.isEmpty, let number = values.int("sequenceNumber") { sequenceNumbers["phoneApps"] = Int64(number) }
        publish()
        var reply = ValueSet([
            "result": .int32(0),
            "contentType": .string(AppCatalogSync.contentType),
            "contractVersion": .double(ValueSet.contractVersion),
            // Must be an Int32. Zero ends the sync with this client recorded as up to date.
            "itemCount": .int32(Int32(wanted.count)),
            "phoneAppsIds": .int64Array(wanted),
        ])
        if let correlation = values.string("correlationVector") { reply["correlationVector"] = .string(correlation) }
        return reply
    }

    /// Merges an app batch: parallel arrays, icons end to end in `content`.
    private func merge(_ values: ValueSet) {
        let ids = values.int64s("phoneAppsIds") ?? [], actions = values.int32s("actions") ?? []
        let packages = values.strings("appPackageNames") ?? [], names = values.strings("appNames") ?? [], versions = values.strings("appVersions") ?? []
        let checksums = values.int64s("checksums") ?? [], sizes = values.int64s("iconSizes") ?? []
        var icons: [Data] = []
        if let blob = values.bytes("content"), sizes.count == ids.count, let pieces = ValueSet.split(blob, sizes: sizes) { icons = pieces }
        for (index, id) in ids.enumerated() {
            // A removed app comes with its ID only.
            if index < actions.count, actions[index] == 2 { apps.removeValue(forKey: id); continue }
            guard index < packages.count, !packages[index].isEmpty else { continue }
            var icon = index < icons.count && !icons[index].isEmpty ? icons[index] : nil
            // An update without an icon keeps the one we have.
            if icon == nil { icon = apps[id]?.icon }
            apps[id] = PhoneApp(id: id, packageName: packages[index], name: index < names.count ? names[index] : "",
                                version: index < versions.count ? versions[index] : "",
                                checksum: index < checksums.count ? checksums[index] : 0, icon: icon)
        }
    }
}
