import QuickLookThumbnailing
import SwiftUI
import WinPhoneCore

/// Files that moved between the phone and this Mac, either way, and what is moving now.
struct FilesView: View {
    @ObservedObject var model: AppModel
    @State private var choosing = false
    @State private var dropTargeted = false
    @State private var filter = Filter.all
    @State private var selection: Set<ReceivedFileEntry.ID> = []

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", received = "Received", sent = "Sent"
        var id: Filter { self }
    }

    private var canSend: Bool { model.actions != nil && model.isConnected && model.fileTransferStatus == nil }

    private var shown: [ReceivedFileEntry] {
        switch filter {
        case .all: return model.receivedFiles
        case .received: return model.receivedFiles.filter { !$0.sent }
        case .sent: return model.receivedFiles.filter(\.sent)
        }
    }

    var body: some View {
        List(selection: $selection) {
            if let status = model.fileTransferStatus {
                TransferRow(status: status, progress: model.fileTransferProgress, sending: model.fileTransferIsSending) { model.actions?.cancelFileTransfer() }
                    .selectionDisabled()
            }
            if let problem = model.fileTransferProblem {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.title3).frame(width: 36)
                    Text(problem).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button { model.fileTransferProblem = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .buttonStyle(.borderless).help("Dismiss").accessibilityLabel("Dismiss")
                }
                .padding(.vertical, 4)
                .selectionDisabled()
            }
            ForEach(shown) { file in
                FileRow(file: file).tag(file.id)
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: ReceivedFileEntry.ID.self) { ids in
            let files = model.receivedFiles.filter { ids.contains($0.id) }
            if !files.isEmpty {
                Button("Open") { for file in files { NSWorkspace.shared.open(file.url) } }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(files.map(\.url)) }
                if canSend {
                    Button(files.count == 1 ? "Send to Phone Again" : "Send to Phone") { model.actions?.sendFiles(files.map(\.url)) }
                }
                Divider()
                Button("Remove from List") { model.receivedFiles.removeAll { ids.contains($0.id) } }
            }
        } primaryAction: { ids in
            for file in model.receivedFiles where ids.contains(file.id) { NSWorkspace.shared.open(file.url) }
        }
        .overlay {
            if shown.isEmpty, model.fileTransferStatus == nil, model.fileTransferProblem == nil { emptyState }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14).fill(Color.accentColor.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7, 5])))
                    .overlay(Label("Send to Phone", systemImage: "arrow.up.circle.fill").font(.title2.weight(.semibold)).foregroundStyle(.tint))
                    .padding(10).allowsHitTesting(false)
            }
        }
        .card()
        .pageInset()
        .dropDestination(for: URL.self) { urls, _ in
            guard canSend, !urls.isEmpty else { return false }
            model.actions?.sendFiles(urls)
            return true
        } isTargeted: { dropTargeted = $0 && canSend }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result, !urls.isEmpty { model.actions?.sendFiles(urls) }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Show files received from the phone, sent to it, or both")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { choosing = true } label: { Label("Send Files…", systemImage: "arrow.up.doc").labelStyle(.titleAndIcon) }
                    .disabled(!canSend)
                    .help("Send files to the phone")
            }
        }
        .navigationTitle("Files")
    }

    @ViewBuilder private var emptyState: some View {
        switch filter {
        case .sent:
            EmptyState(title: "Nothing sent yet", symbol: "arrow.up.doc", tint: SidebarItem.files.tint, message: "Drop files here or choose Send Files. They arrive in the phone's Downloads folder.")
        case .received where !model.filesEnabled:
            EmptyState(title: "Receiving is off", symbol: "arrow.down.doc", tint: .orange, message: "Turn on receiving files in Settings.")
        case .received:
            EmptyState(title: "Nothing received yet", symbol: "arrow.down.doc", tint: SidebarItem.files.tint, message: "On the phone, share a file to Link to Windows and choose this Mac. Files are saved to Downloads.")
        case .all:
            EmptyState(title: "No Files", symbol: "folder", tint: SidebarItem.files.tint, message: "Drop files here to send them to your phone. Files shared from the phone to this Mac are saved to Downloads. Fastest when both devices are on the same Wi-Fi network.") {
                Button("Send Files…") { choosing = true }.disabled(!canSend)
            }
        }
    }
}

/// The transfer in progress: which way it goes, what it is doing and how far it is.
private struct TransferRow: View {
    let status: String
    let progress: Double?
    let sending: Bool
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: sending ? "arrow.up.circle" : "arrow.down.circle")
                .font(.system(size: 28, weight: .light)).foregroundStyle(.tint).frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(status).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    if let progress { Text(progress, format: .percent.precision(.fractionLength(0))).monospacedDigit().foregroundStyle(.secondary) }
                }
                .font(.callout)
                if let progress {
                    ProgressView(value: progress).progressViewStyle(.linear)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
            Button(action: cancel) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.borderless).help("Stop the transfer").accessibilityLabel("Stop the transfer")
        }
        .padding(.vertical, 6)
    }
}

/// One transferred file: its icon marked with the way it went, its name, size and time.
private struct FileRow: View {
    let file: ReceivedFileEntry
    @State private var hovering = false

    private var exists: Bool { FileManager.default.fileExists(atPath: file.url.path) }

    private var detail: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)
        let day = Calendar.current.isDateInToday(file.date) ? file.date.formatted(date: .omitted, time: .shortened)
            : file.date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        return "\(file.sent ? "Sent to phone" : "Received") · \(size) · \(day)"
    }

    var body: some View {
        let exists = exists
        HStack(spacing: 12) {
            FileThumbnail(url: file.url)
                .frame(width: 36, height: 36)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: file.sent ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, file.sent ? Color.blue : Color.green)
                        .font(.system(size: 15))
                        .background(Circle().fill(.background).padding(-1))
                        .offset(x: 4, y: 3)
                }
                .opacity(exists ? 1 : 0.45)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).lineLimit(1).truncationMode(.middle)
                Text(exists ? detail : detail + " · no longer at its place").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { NSWorkspace.shared.activateFileViewerSelecting([file.url]) } label: { Image(systemName: "magnifyingglass.circle.fill") }
                .buttonStyle(.borderless).font(.title3).foregroundStyle(.secondary)
                .help("Show in Finder").accessibilityLabel("Show in Finder")
                .opacity(hovering && exists ? 1 : 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .draggable(file.url)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(file.name), \(detail)")
    }
}

/// A file's preview picture where the system can make one, its icon otherwise.
private struct FileThumbnail: View {
    let url: URL
    @State private var preview: NSImage?

    var body: some View {
        Image(nsImage: preview ?? NSWorkspace.shared.icon(forFile: url.path))
            .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            .task(id: url) {
                let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 36, height: 36),
                                                           scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
                preview = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
            }
    }
}
