import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WinPhoneCore

/// Decoded thumbnails, so scrolling does not decode the same JPEG again and again.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    init() { cache.countLimit = 600 }

    func image(for photo: PhonePhoto) -> NSImage? {
        guard let data = photo.thumbnail else { return nil }
        let key = "\(photo.id)-\(photo.checksum)-\(data.count)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

/// The phone's recent photos as a grid by day, close together and square as in Photos.
/// Thumbnails load as cells come into view.
struct PhotosView: View {
    @ObservedObject var model: AppModel
    @State private var opened: PhonePhoto?
    @State private var selected: PhonePhoto.ID?
    @AppStorage("photos.cellSize") private var cellSize = 150.0

    struct Day: Identifiable {
        var id: Date
        var title: String
        var photos: [PhonePhoto]
    }

    /// The photos by the day they were taken, newest day first, in the order given.
    static func days(_ photos: [PhonePhoto], now: Date = Date(), calendar: Calendar = .current) -> [Day] {
        var days: [Day] = []
        for photo in photos {
            let start = calendar.startOfDay(for: photo.taken)
            if days.last?.id != start { days.append(Day(id: start, title: CallsView.dayTitle(start, now: now, calendar: calendar), photos: [])) }
            days[days.count - 1].photos.append(photo)
        }
        return days
    }

    var body: some View {
        Group {
            if model.photoAccessMissing {
                EmptyState(title: "Photo access is off", symbol: "photo.badge.exclamationmark", tint: .orange, message: "On the phone, open Link to Windows and allow it to access photos.")
            } else if model.visiblePhotos.isEmpty {
                EmptyState(title: "No Photos", symbol: "photo.on.rectangle", tint: SidebarItem.photos.tint, message: "Recent photos and screenshots from your phone appear here.")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: cellSize, maximum: cellSize * 1.6), spacing: 6)], alignment: .leading, spacing: 6,
                              pinnedViews: [.sectionHeaders]) {
                        ForEach(PhotosView.days(model.visiblePhotos)) { day in
                            Section {
                                ForEach(day.photos) { photo in
                                    PhotoCell(photo: photo, isSelected: selected == photo.id)
                                        .onAppear { if photo.thumbnail == nil { model.actions?.needThumbnails([photo.id]) } }
                                        // One click selects, two open, as in Photos and the Finder.
                                        .onTapGesture(count: 2) { opened = photo }
                                        .simultaneousGesture(TapGesture().onEnded { selected = photo.id })
                                        // Dragged out, the photo itself goes along, fetched when it is dropped.
                                        .onDrag {
                                            selected = photo.id
                                            return PhotoExport.provider(for: photo, model: model)
                                        } preview: {
                                            PhotoCell(photo: photo).frame(width: 96, height: 96).clipShape(RoundedRectangle(cornerRadius: 8))
                                        }
                                        .contextMenu {
                                            Button("Open") { opened = photo }
                                            Button("Save to Downloads") { PhotoExport.saveToDownloads(photo, model: model) }
                                            Button("Copy") { PhotoExport.copy(photo, model: model) }
                                            Divider()
                                            Text(photo.taken.formatted(date: .abbreviated, time: .shortened))
                                        }
                                        .accessibilityAddTraits(.isButton)
                                        .accessibilityLabel("Photo taken \(photo.taken.formatted(date: .abbreviated, time: .shortened))")
                                        .accessibilityAction { opened = photo }
                                }
                            } header: {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(day.title).font(.title3.weight(.semibold))
                                    Text("\(day.photos.count)").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                                    Spacer()
                                }
                                .padding(.horizontal, 2).padding(.top, 10).padding(.bottom, 6)
                                .background(Theme.canvas)
                            }
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 16)
                }
                // Return opens the selected photo.
                .background {
                    Button("") { if let photo = model.visiblePhotos.first(where: { $0.id == selected }) { opened = photo } }
                        .keyboardShortcut(.defaultAction).opacity(0).accessibilityHidden(true)
                }
            }
        }
        .navigationTitle("Photos")
        .sectionSubtitle(model.visiblePhotos.isEmpty ? "" : "\(model.visiblePhotos.count) recent")
        .toolbar {
            ToolbarItem {
                Slider(value: $cellSize, in: 90...260) {
                    Text("Size")
                } minimumValueLabel: {
                    Image(systemName: "photo").font(.caption2)
                } maximumValueLabel: {
                    Image(systemName: "photo").font(.body)
                }
                .labelsHidden().frame(width: 150)
                .help("Thumbnail size")
            }
            ToolbarItem {
                Button { model.actions?.refreshPhotos() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Ask the phone for its photo list again")
            }
        }
        .sheet(item: $opened) { photo in
            PhotoDetailView(photo: photo, photos: model.visiblePhotos, model: model) { opened = nil }
        }
    }
}

/// Photos taken out of the grid without opening them: saved, copied, or dragged elsewhere.
/// Each asks the phone for the photo itself; the grid only holds small previews.
@MainActor
enum PhotoExport {
    /// A place in the folder for a file of this name that takes no other file's: the name
    /// itself, or with a number before its extension.
    nonisolated static func freeURL(for name: String, in folder: URL) -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var target = folder.appendingPathComponent(name)
        var count = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(count)" : "\(base) \(count).\(ext)")
            count += 1
        }
        return target
    }

    /// The kind of file to promise before the photo is here. A photo the phone reduces
    /// arrives as a JPEG whatever its name says.
    nonisolated static func promisedType(for photo: PhonePhoto) -> UTType {
        if photo.arrivesReduced { return .jpeg }
        guard let type = UTType(filenameExtension: (photo.name as NSString).pathExtension), type.conforms(to: .image) else { return .jpeg }
        return type
    }

    /// The name a dropped photo gets: the phone's, with its extension where that is the
    /// extension of what will arrive (the system would otherwise write ".jpeg" for ".jpg").
    nonisolated static func suggestedName(for photo: PhonePhoto) -> String {
        let base = (photo.name as NSString).deletingPathExtension, ext = (photo.name as NSString).pathExtension
        guard !base.isEmpty else { return "Photo \(photo.id)" }
        return UTType(filenameExtension: ext) == promisedType(for: photo) ? photo.name : base
    }

    static func saveToDownloads(_ photo: PhonePhoto, model: AppModel) {
        Task {
            guard let fetched = await model.actions?.fetchPhoto(photo.id),
                  let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return NSSound.beep() }
            let target = freeURL(for: PhotoDetailView.fileName(for: photo, fetched: fetched), in: folder)
            do {
                try fetched.data.write(to: target, options: .withoutOverwriting)
                // As the system's own downloads do: the Downloads stack in the Dock takes note.
                DistributedNotificationCenter.default().post(name: Notification.Name("com.apple.DownloadFileFinished"), object: target.path)
            } catch {
                NSSound.beep()
            }
        }
    }

    static func copy(_ photo: PhonePhoto, model: AppModel) {
        Task {
            guard let fetched = await model.actions?.fetchPhoto(photo.id), let image = NSImage(data: fetched.data) else { return NSSound.beep() }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
        }
    }

    /// Where photos wait while they are being dropped somewhere; emptied at each launch.
    private static let dragFolder: URL = {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Phone Mac Link Drag", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    /// What a drag carries: the promise of the photo as a file, kept when it is dropped.
    static func provider(for photo: PhonePhoto, model: AppModel) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = suggestedName(for: photo)
        let folder = dragFolder
        provider.registerFileRepresentation(forTypeIdentifier: promisedType(for: photo).identifier, fileOptions: [], visibility: .all) { [weak model] completion in
            let progress = Progress(totalUnitCount: 1)
            nonisolated(unsafe) let done = completion
            Task { @MainActor in
                guard let fetched = await model?.actions?.fetchPhoto(photo.id) else {
                    done(nil, false, CocoaError(.fileReadUnknown))
                    return
                }
                let place = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
                do {
                    try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
                    let file = place.appendingPathComponent(PhotoDetailView.fileName(for: photo, fetched: fetched))
                    try fetched.data.write(to: file)
                    progress.completedUnitCount = 1
                    done(file, false, nil)
                } catch {
                    done(nil, false, error)
                }
            }
            return progress
        }
        return provider
    }
}

struct PhotoCell: View {
    let photo: PhonePhoto
    var isSelected = false

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image = ThumbnailCache.shared.image(for: photo) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        Image(systemName: "photo").font(.title2).foregroundStyle(.tertiary)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                if photo.mimeType.hasPrefix("video") {
                    Image(systemName: "video.fill").font(.caption).foregroundStyle(.white).shadow(radius: 2).padding(6)
                }
            }
            .overlay {
                if isSelected { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 3) }
            }
            .contentShape(Rectangle())
    }
}

/// One photo, fetched from the phone when opened, with Save, Copy and Delete, and the arrow
/// keys to go to its neighbours.
struct PhotoDetailView: View {
    @State private var photo: PhonePhoto
    let photos: [PhonePhoto]
    @ObservedObject var model: AppModel
    let close: () -> Void

    @State private var fetched: FetchedPhoto?
    @State private var failed = false
    @State private var confirmingDelete = false
    @State private var deleting = false
    @State private var deleteProblem: String?
    @State private var hovering = false

    init(photo: PhonePhoto, photos: [PhonePhoto] = [], model: AppModel, close: @escaping () -> Void) {
        _photo = State(initialValue: photo)
        self.photos = photos
        self.model = model
        self.close = close
    }

    private var index: Int? { photos.firstIndex { $0.id == photo.id } }

    /// Moves to the photo before or after this one in the grid.
    private func step(_ by: Int) {
        guard let index, photos.indices.contains(index + by) else { return }
        photo = photos[index + by]
    }

    private func arrow(_ symbol: String, _ label: String, by: Int, key: KeyEquivalent) -> some View {
        Button { step(by) } label: {
            Image(systemName: symbol).font(.title2.weight(.semibold)).foregroundStyle(.white)
                .frame(width: 36, height: 36).background(.black.opacity(0.45), in: Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(key, modifiers: [])
        .opacity(hovering ? 1 : 0)
        .disabled(index.map { !photos.indices.contains($0 + by) } ?? true)
        .help(label).accessibilityLabel(label)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let fetched, let image = NSImage(data: fetched.data) {
                    Image(nsImage: image).resizable().scaledToFit()
                } else if failed {
                    ContentUnavailableView("Could not load this photo", systemImage: "exclamationmark.triangle",
                                           description: Text("The phone did not send it. Try again.")).foregroundStyle(.white)
                } else {
                    // Show the thumbnail right away while the image is on its way.
                    if let preview = ThumbnailCache.shared.image(for: photo) {
                        Image(nsImage: preview).resizable().scaledToFit().blur(radius: 6).opacity(0.7)
                    }
                    ProgressView().controlSize(.large).tint(.white)
                }
                HStack {
                    arrow("chevron.left", "Previous photo", by: -1, key: .leftArrow)
                    Spacer()
                    arrow("chevron.right", "Next photo", by: 1, key: .rightArrow)
                }
                .padding(.horizontal, 12)
            }
            .frame(minWidth: 560, minHeight: 380)
            .onHover { hovering = $0 }
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(photo.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 12)
                if let deleteProblem { Text(deleteProblem).font(.caption).foregroundStyle(.orange).lineLimit(2) }
                if deleting { ProgressView().controlSize(.small) }
                Group {
                    Button(role: .destructive) { confirmingDelete = true } label: { Image(systemName: "trash") }
                        .disabled(deleting).help("Delete this photo from the phone").accessibilityLabel("Delete from phone")
                    Button { copy() } label: { Image(systemName: "doc.on.doc") }
                        .disabled(fetched == nil).help("Copy").accessibilityLabel("Copy")
                        .keyboardShortcut("c")
                    Button { save() } label: { Image(systemName: "square.and.arrow.down") }
                        .disabled(fetched == nil).help("Save to this Mac…").accessibilityLabel("Save")
                        .keyboardShortcut("s")
                }
                .buttonStyle(.borderless).font(.title3)
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .frame(width: 820, height: 600)
        .confirmationDialog("Delete this photo from your phone?", isPresented: $confirmingDelete) {
            Button("Delete from Phone", role: .destructive) {
                deleting = true
                deleteProblem = nil
                let doomed = photo
                Task { @MainActor in
                    let problem = await model.actions?.deletePhoto(doomed)
                    deleting = false
                    if let problem { deleteProblem = problem } else { close() }
                }
            }
        } message: {
            Text("It is removed from the phone's gallery, not only from this Mac. This cannot be undone from here.")
        }
        .task(id: photo.id) {
            fetched = nil
            failed = false
            deleteProblem = nil
            let result = await model.actions?.fetchPhoto(photo.id)
            // Another photo may have been stepped to meanwhile; its own fetch is under way.
            guard !Task.isCancelled else { return }
            if let result { fetched = result } else { failed = true }
        }
    }

    private var caption: String {
        var parts = [photo.taken.formatted(date: .abbreviated, time: .shortened)]
        let size = photo.displaySize
        if size.width > 0, size.height > 0 { parts.append("\(size.width) × \(size.height)") }
        if photo.arrivesReduced { parts.append("the phone sends a reduced copy") }
        return parts.joined(separator: " · ")
    }

    private func copy() {
        guard let fetched, let image = NSImage(data: fetched.data) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    private func save() {
        guard let fetched else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = PhotoDetailView.fileName(for: photo, fetched: fetched)
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        if let type = UTType(filenameExtension: fetched.fileExtension) { panel.allowedContentTypes = [type] }
        if panel.runModal() == .OK, let url = panel.url { try? fetched.data.write(to: url) }
    }

    /// The phone's file name with the extension the bytes actually have: a large HEIC photo
    /// arrives as a JPEG under its original name.
    static func fileName(for photo: PhonePhoto, fetched: FetchedPhoto) -> String {
        let base = (photo.name as NSString).deletingPathExtension
        return (base.isEmpty ? "Photo \(photo.id)" : base) + "." + fetched.fileExtension
    }
}
