import AppKit
import SwiftUI
import WinPhoneCore

/// Small pictures of the phone's files, kept while the app runs so that scrolling back does
/// not ask the phone again.
@MainActor
final class PhoneFilePreviews {
    static let shared = PhoneFilePreviews()
    private let cache = NSCache<NSString, NSImage>()
    /// Files the phone gave no picture for, and when: asked again after a while, since the
    /// reason may have been a connection that was just coming back.
    private var missing: [String: Date] = [:]
    static let retryAfter: TimeInterval = 90

    init() { cache.countLimit = 800 }

    static func key(_ file: PhoneFile, side: Int) -> String { "\(file.id)-\(file.checksum)-\(side)" }

    func image(for file: PhoneFile, side: Int) -> NSImage? { cache.object(forKey: PhoneFilePreviews.key(file, side: side) as NSString) }

    /// The picture from the cache or from the phone; nil where the phone has none, which is
    /// remembered so that it is not asked again and again.
    func load(_ file: PhoneFile, side: Int, model: AppModel) async -> NSImage? {
        let key = PhoneFilePreviews.key(file, side: side)
        if let cached = cache.object(forKey: key as NSString) { return cached }
        guard file.hasPreview else { return nil }
        if let since = missing[key], Date().timeIntervalSince(since) < PhoneFilePreviews.retryAfter { return nil }
        guard let data = await model.actions?.phoneFilePreview(file, side: side), let image = NSImage(data: data) else {
            missing[key] = Date()
            return nil
        }
        missing[key] = nil
        cache.setObject(image, forKey: key as NSString)
        return image
    }

    /// Starts afresh: another phone, or the user asked for everything anew.
    func forget() {
        missing.removeAll()
        cache.removeAllObjects()
    }
}

/// The phone's storage, folder by folder: names, sizes, dates and small previews. A file's
/// content is fetched one file at a time, over a direct connection like a share from the phone.
struct StorageView: View {
    @ObservedObject var model: AppModel
    /// The folder shown; nil is the top.
    @State private var folder: String?
    @State private var search = ""
    @State private var selected: PhoneFile.ID?
    @State private var previewed: PhoneFile?
    @AppStorage("storage.order") private var order = Order.name.rawValue

    enum Order: String, CaseIterable, Identifiable {
        case name = "Name", newest = "Newest First", largest = "Largest First"
        var id: String { rawValue }
    }

    /// A folder's contents in the chosen order; folders stay on top.
    static func ordered(_ files: [PhoneFile], by order: Order) -> [PhoneFile] {
        switch order {
        case .name: return files
        case .newest: return files.filter(\.isDirectory) + files.filter { !$0.isDirectory }.sorted { $0.modified > $1.modified }
        case .largest: return files.filter(\.isDirectory) + files.filter { !$0.isDirectory }.sorted { $0.size > $1.size }
        }
    }

    /// A folder's name for the path bar: the top is the phone itself.
    static func title(of folder: String, root: String) -> String {
        folder == root ? "Phone" : (folder as NSString).lastPathComponent
    }

    static func symbol(for file: PhoneFile) -> String {
        if file.isDirectory { return "folder.fill" }
        switch file.kind {
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "music.note"
        case .document: return "doc.text"
        case .playlist: return "music.note.list"
        case .subtitle: return "captions.bubble"
        case .other, .none: return "doc"
        }
    }

    private var tree: PhoneFileTree { model.storageTree }
    private var current: String { folder.flatMap { $0.hasPrefix(tree.root) ? $0 : nil } ?? tree.root }
    private var searching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }
    private var shown: [PhoneFile] {
        searching ? tree.search(search) : StorageView.ordered(tree.children(of: current), by: Order(rawValue: order) ?? .name)
    }

    var body: some View {
        Group {
            if model.storageListed {
                list
            } else {
                switch model.storageState {
                case .needsPermission:
                    EmptyState(title: "The Phone Has Not Allowed It", symbol: "lock.doc", tint: .orange, message: "On the phone, open Link to Windows and allow it access to all files. The list appears here once that is done.") {
                        Button("Try Again") { model.actions?.loadPhoneFiles(again: false) }
                    }
                case .failed(let reason):
                    EmptyState(title: "The Files Could Not Be Listed", symbol: "exclamationmark.triangle", tint: .orange, message: reason) {
                        Button("Try Again") { model.actions?.loadPhoneFiles(again: false) }.disabled(!model.isConnected)
                    }
                case .loading(let received, let expected):
                    VStack(spacing: 12) {
                        if let expected, expected > 0 {
                            ProgressView(value: Double(min(received, expected)), total: Double(expected)).frame(width: 220)
                        } else {
                            ProgressView().controlSize(.large)
                        }
                        Text(received > 0 ? "Reading the phone's files… \(received.formatted())" : "Asking the phone for its files…")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                case .ready:
                    // The list is here and being sorted into folders.
                    ProgressView().controlSize(.large)
                case .idle:
                    EmptyState(title: "Phone Storage", symbol: "internaldrive", tint: SidebarItem.storage.tint, message: model.isConnected ? "Look through the folders and files on your phone." : "Connect the phone to look through its files.") {
                        Button("Show Files") { model.actions?.loadPhoneFiles(again: false) }.disabled(!model.isConnected)
                    }
                }
            }
        }
        .navigationTitle("Phone Storage")
        .sectionSubtitle(subtitle)
        // Opening the section is the wish to see the files: the phone is asked then, not before.
        .onAppear { if model.isConnected, model.storageState == .idle { model.actions?.loadPhoneFiles(again: false) } }
        .onChange(of: model.storageState) { _, state in
            // A new session after a reconnect knows nothing yet; the section on screen asks again.
            if state == .idle, model.isConnected, model.selection == .storage { model.actions?.loadPhoneFiles(again: false) }
        }
        .sheet(item: $previewed) { file in StoragePreview(file: file, model: model) { previewed = nil } }
    }

    private var subtitle: String {
        guard model.storageListed else { return "" }
        var parts = ["\(tree.fileCount.formatted()) files"]
        if let space = model.storageSpace, space.total > 0 {
            parts.append("\(space.available.formatted(.byteCount(style: .file))) free of \(space.total.formatted(.byteCount(style: .file)))")
        }
        return parts.joined(separator: " · ")
    }

    private func open(_ file: PhoneFile) {
        if file.isDirectory {
            search = ""
            folder = file.path
            selected = nil
        } else {
            previewed = file
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            // Where one is, each step a way back.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(tree.trail(to: current), id: \.self) { step in
                        if step != tree.root { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                        Button(StorageView.title(of: step, root: tree.root)) { folder = step; search = "" }
                            .buttonStyle(.borderless).fontWeight(step == current && !searching ? .semibold : .regular)
                    }
                    if searching {
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        Text("Search").fontWeight(.semibold)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 7)
            }
            // Search sits with the folder trail, as it does above Messages' and Contacts' lists:
            // a search field in the toolbar takes the room that keeps its buttons to the right.
            .safeAreaInset(edge: .trailing, spacing: 0) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search the phone's files", text: $search).textFieldStyle(.plain)
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                            .buttonStyle(.plain).accessibilityLabel("Clear the search")
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .frame(width: 240)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .padding(.trailing, 10)
            }
            .padding(.vertical, 4)
            Divider()
            List(selection: $selected) {
                ForEach(shown) { file in
                    StorageRow(file: file, model: model, place: searching ? StorageView.place(of: file, root: tree.root) : nil)
                        .tag(file.id)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { open(file) }
                        .simultaneousGesture(TapGesture().onEnded { selected = file.id })
                        .contextMenu {
                            Button(file.isDirectory ? "Open" : "Look at It") { open(file) }
                            if !file.isDirectory {
                                Button("Download to This Mac") { model.actions?.downloadPhoneFile(file) }.disabled(!canDownload(file))
                            }
                            if searching, !file.isDirectory {
                                Button("Show in Its Folder") { search = ""; folder = file.parentPath; selected = file.id }
                            }
                            Button("Copy Name") { copy(file.name) }
                            Button("Copy Path on Phone") { copy(file.path) }
                        }
                }
            }
            .listStyle(.inset)
            .overlay {
                if shown.isEmpty {
                    if searching { ContentUnavailableView.search(text: search) } else { EmptyState(title: "Empty Folder", symbol: "folder.fill", tint: SidebarItem.storage.tint) }
                }
            }
            // Return opens what is selected.
            .background {
                Button("") { if let file = shown.first(where: { $0.id == selected }) { open(file) } }
                    .keyboardShortcut(.defaultAction).opacity(0).accessibilityHidden(true)
            }
            Divider()
            // A download under way, or what became of the last one; else how to get a file.
            HStack(spacing: 8) {
                if case .failed(let reason) = model.storageState {
                    // The list on show is the last one that arrived.
                    Label("This list may be out of date. \(reason)", systemImage: "exclamationmark.triangle").lineLimit(2)
                    Spacer()
                    Button("Refresh") { model.actions?.loadPhoneFiles(again: true) }.controlSize(.small).disabled(!model.isConnected)
                } else if let status = model.fileTransferStatus {
                    ProgressView(value: model.fileTransferProgress ?? 0).frame(width: 120)
                    Text(status).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Stop") { model.actions?.cancelFileTransfer() }.controlSize(.small)
                } else if let problem = model.fileTransferProblem {
                    Label(problem, systemImage: "exclamationmark.triangle").lineLimit(2)
                    Spacer()
                } else {
                    Label("Right-click a file to download it to this Mac. It arrives in Downloads and is listed under Files; both devices need to be on the same Wi-Fi.", systemImage: "info.circle")
                    Spacer()
                }
            }
            .font(.footnote).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 6)
        }
        .card()
        .pageInset()
        .toolbar {
            ToolbarItem {
                Button { folder = PhoneFileTree.parent(of: current); search = "" } label: { Label("Enclosing Folder", systemImage: "chevron.up") }
                    .disabled(current == tree.root && !searching)
                    .help("Go to the folder this one lies in")
            }
            ToolbarItem {
                Picker("Order", selection: $order) {
                    ForEach(Order.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                .help("How a folder's files are ordered")
            }
            ToolbarItem {
                Button {
                    PhoneFilePreviews.shared.forget()
                    model.actions?.loadPhoneFiles(again: true)
                } label: {
                    if case .loading = model.storageState { ProgressView().controlSize(.small) } else { Label("Refresh", systemImage: "arrow.clockwise") }
                }
                .help("Ask the phone to look over its storage and list it again")
                .disabled(!model.isConnected || model.storageState.isLoading)
            }
        }
    }

    /// Whether a file can be fetched now: one at a time, and only what the phone has an address for.
    private func canDownload(_ file: PhoneFile) -> Bool {
        model.isConnected && model.filesEnabled && model.fileTransferStatus == nil && !file.isDirectory && !file.uri.isEmpty
    }

    /// Where a found file lies, told from the top: "DCIM › Camera".
    static func place(of file: PhoneFile, root: String) -> String {
        let parent = file.parentPath
        guard parent.hasPrefix(root), parent != root else { return "Phone" }
        return parent.dropFirst(root.count).split(separator: "/").joined(separator: " › ")
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension PhoneFilesSync.State {
    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

/// One file or folder: a picture or a sign of its kind, its name, and for a file its size and date.
struct StorageRow: View {
    let file: PhoneFile
    @ObservedObject var model: AppModel
    /// The folder it lies in, shown under the name in search results.
    var place: String?
    @State private var picture: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let picture {
                    Image(nsImage: picture).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: StorageView.symbol(for: file)).font(.system(size: 17))
                        .foregroundStyle(file.isDirectory ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 30, height: 30).clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name).lineLimit(1).truncationMode(.middle)
                if let place { Text(place).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head) }
            }
            Spacer(minLength: 12)
            if !file.isDirectory {
                Text(file.size.formatted(.byteCount(style: .file))).foregroundStyle(.secondary).monospacedDigit()
                    .frame(width: 80, alignment: .trailing)
                Text(file.modified == .distantPast ? "" : file.modified.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.secondary)
                    .frame(width: 100, alignment: .trailing)
            } else {
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 1)
        .task(id: PhoneFilePreviews.key(file, side: 96)) {
            picture = PhoneFilePreviews.shared.image(for: file, side: 96)
            guard picture == nil, file.hasPreview else { return }
            picture = await PhoneFilePreviews.shared.load(file, side: 96, model: model)
        }
    }
}

/// A closer look at one file: the largest picture the phone gives of it, and what is known.
struct StoragePreview: View {
    let file: PhoneFile
    @ObservedObject var model: AppModel
    var close: () -> Void
    @State private var picture: NSImage?
    @State private var asked = false

    var body: some View {
        VStack(spacing: 14) {
            Group {
                if let picture {
                    Image(nsImage: picture).resizable().aspectRatio(contentMode: .fit)
                } else if file.hasPreview, !asked {
                    ProgressView().controlSize(.large)
                } else {
                    Image(systemName: StorageView.symbol(for: file)).font(.system(size: 64)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 420, height: 320)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(spacing: 4) {
                Text(file.name).font(.headline).multilineTextAlignment(.center).textSelection(.enabled)
                Text([file.size.formatted(.byteCount(style: .file)), file.modified == .distantPast ? nil : file.modified.formatted(date: .abbreviated, time: .shortened)]
                    .compactMap { $0 }.joined(separator: " · ")).foregroundStyle(.secondary)
                Text(StorageView.place(of: file, root: model.storageTree.root)).font(.callout).foregroundStyle(.secondary)
                if file.hasPreview {
                    Text("A small preview from the phone, not the file itself.").font(.footnote).foregroundStyle(.tertiary).padding(.top, 2)
                }
            }
            HStack {
                Button("Download to This Mac") {
                    model.actions?.downloadPhoneFile(file)
                    close()
                }
                .disabled(!model.isConnected || !model.filesEnabled || model.fileTransferStatus != nil || file.uri.isEmpty)
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task(id: file.id) {
            picture = await PhoneFilePreviews.shared.load(file, side: 512, model: model)
            asked = true
        }
    }
}
