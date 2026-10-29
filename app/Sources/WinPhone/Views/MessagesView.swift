import SwiftUI
import UniformTypeIdentifiers
import WinPhoneCore

/// Text conversations: the list on the left, the selected thread on the right.
struct MessagesView: View {
    @ObservedObject var model: AppModel
    @State private var selected: Int64?
    @State private var composingNew = false
    @State private var composeNumber = ""
    @State private var search = ""

    /// The conversations to list: all, or those whose name or texts contain the search words.
    private var listed: [Conversation] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return model.conversations }
        return model.conversations.filter { conversation in
            model.title(for: conversation).localizedCaseInsensitiveContains(query)
                || conversation.participants.contains { $0.localizedCaseInsensitiveContains(query) }
                || conversation.messages.contains { $0.body.localizedCaseInsensitiveContains(query) }
        }
    }

    private var current: Conversation? {
        model.conversations.first { $0.id == selected } ?? model.conversations.first
    }

    var body: some View {
        Group {
            if model.messagingAccessMissing {
                EmptyState(title: "Message access is off", symbol: "exclamationmark.bubble", tint: .orange, message: "On the phone, open Link to Windows and allow it to read and send text messages.")
            } else if model.conversations.isEmpty {
                EmptyState(title: "No messages yet", symbol: "message", tint: SidebarItem.messages.tint, message: "Text messages from the last 30 days on your phone appear here.") {
                    Button("New Message") { composingNew = true }
                }
            } else {
                // Two cards side by side, as Telegram sets its list beside the conversation.
                HStack(spacing: 12) {
                    VStack(spacing: 0) {
                        // Search sits on top of the list it narrows, as in Messages.
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField("Search", text: $search).textFieldStyle(.plain)
                            if !search.isEmpty {
                                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                                    .buttonStyle(.borderless).accessibilityLabel("Clear search")
                            }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)
                        List(selection: Binding(get: { current?.id }, set: { selected = $0 })) {
                            ForEach(listed) { conversation in
                                ConversationRow(conversation: conversation, unread: model.unreadCount(conversation),
                                                title: model.title(for: conversation), photo: model.contact(for: conversation)?.photo)
                                    .tag(conversation.id)
                            }
                        }
                        .listStyle(.inset)
                        .overlay {
                            if listed.isEmpty { ContentUnavailableView.search(text: search) }
                        }
                    }
                    .frame(width: 300)
                    .card()
                    if let current {
                        ThreadView(conversation: current, model: model).frame(minWidth: 300, maxWidth: .infinity)
                            .card()
                            // A different thread is a different view: a draft never follows
                            // along to another person.
                            .id(current.id)
                            // Showing a thread reads it, also when a new text arrives while it
                            // is open. The thread shown is pinned, so a text arriving in another
                            // conversation does not swap it in under the user's hands.
                            .onAppear { selected = current.id; model.markRead(current) }
                            .onChange(of: current.id) { selected = current.id; model.markRead(current) }
                            .onChange(of: current.messages.count) { model.markRead(current) }
                    }
                }
                .pageInset()
            }
        }
        .navigationTitle("Messages")
        .toolbar {
            Button { model.actions?.refreshMessages() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .help("Ask the phone for its messages again")
            Button { composeNumber = ""; composingNew = true } label: { Label("New Message", systemImage: "square.and.pencil") }
                .help("Start a new conversation")
        }
        .sheet(isPresented: $composingNew) {
            NewMessageView(contacts: model.contacts, number: composeNumber) { number, text in
                model.actions?.startConversation(with: number, text: text)
                composingNew = false
            } cancel: { composingNew = false }
        }
        .onAppear(perform: openRequested)
        .onChange(of: model.messageTarget) { _, _ in openRequested() }
        .onChange(of: model.conversationTarget) { _, _ in openRequested() }
    }

    /// A conversation was asked for elsewhere, by a notification's banner, or someone was
    /// chosen in Contacts: show that conversation, or start one with the number.
    private func openRequested() {
        if let id = model.conversationTarget {
            model.conversationTarget = nil
            if model.conversations.contains(where: { $0.id == id }) { selected = id; search = "" }
        }
        guard let number = model.messageTarget else { return }
        model.messageTarget = nil
        if let conversation = model.conversation(with: number) {
            selected = conversation.id
        } else {
            composeNumber = number
            composingNew = true
        }
    }
}

struct ConversationRow: View {
    let conversation: Conversation
    /// Unread texts, taking into account what was read on this Mac.
    var unread = 0
    /// The title with contact names filled in; nil shows the addresses.
    var title: String?
    var photo: Data?

    private var shownTitle: String { title ?? conversation.title }

    /// The newest thing in the thread: a message being sent, or the last one synced.
    var preview: String {
        if let pending = conversation.pending.last { return pending.body }
        guard let last = conversation.lastMessage else { return "" }
        if last.body.isEmpty { return last.attachmentCount > 0 ? "Attachment" : "" }
        return last.isIncoming ? last.body : "You: \(last.body)"
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(unread > 0 ? Color.accentColor : Color.clear).frame(width: 8, height: 8)
            ContactAvatar(name: shownTitle, photo: photo, isGroup: conversation.participants.count > 1, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(shownTitle).fontWeight(.semibold).lineLimit(1)
                    Spacer(minLength: 6)
                    if conversation.lastActivity > .distantPast {
                        Text(MessagesFormat.short(conversation.lastActivity)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                // Two lines always, so that every row is as tall as the next.
                Text(preview.isEmpty ? " " : preview).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(shownTitle)\(unread > 0 ? ", \(unread) unread" : ""). \(preview)")
    }
}

/// A contact's photo, or initials on a tinted circle.
struct ContactAvatar: View {
    let name: String
    let photo: Data?
    var isGroup = false
    var size: CGFloat = 32

    /// Up to two initials of a name; nothing for a bare number.
    static func initials(_ name: String) -> String {
        let words = name.split(separator: " ").filter { $0.first?.isLetter == true }
        return words.prefix(2).compactMap { $0.first.map { String($0).uppercased() } }.joined()
    }

    var body: some View {
        Group {
            if let photo, let image = NSImage(data: photo) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Circle().fill(Color.accentColor.opacity(0.18))
                    let initials = ContactAvatar.initials(name)
                    if isGroup {
                        Image(systemName: "person.2.fill").font(.system(size: size * 0.4)).foregroundStyle(.tint)
                    } else if initials.isEmpty {
                        Image(systemName: "person.fill").font(.system(size: size * 0.45)).foregroundStyle(.tint)
                    } else {
                        Text(initials).font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.tint)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

enum MessagesFormat {
    /// Time today, weekday this week, date otherwise.
    static func short(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day, days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(date: .numeric, time: .omitted)
    }

    /// The line between two stretches of a conversation: the day in words, then the time.
    static func separator(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        let age = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch age {
        case 0: return "Today \(time)"
        case 1: return "Yesterday \(time)"
        case 2..<7: return "\(date.formatted(.dateTime.weekday(.wide))) \(time)"
        default: return "\(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) at \(time)"
        }
    }

    /// Where a message stands among its neighbours: whether a time line goes before it, and
    /// whether it follows the one before closely enough to sit right under it.
    static func placement(of index: Int, in messages: [PhoneMessage]) -> (showsTime: Bool, joins: Bool) {
        guard index > 0 else { return (true, false) }
        let message = messages[index], before = messages[index - 1]
        let gap = message.date.timeIntervalSince(before.date)
        let showsTime = gap >= 15 * 60 || !Calendar.current.isDate(message.date, inSameDayAs: before.date)
        return (showsTime, !showsTime && before.isIncoming == message.isIncoming && gap < 2 * 60)
    }
}

/// One thread as bubbles, with a field to answer.
struct ThreadView: View {
    let conversation: Conversation
    @ObservedObject var model: AppModel
    @State private var draft = ""
    @State private var attached: [OutgoingAttachment] = []
    @State private var attachProblem: String?
    @State private var dialNotice: String?

    /// The number to dial for a one-to-one conversation with a phone number; senders such
    /// as "Parcel" have a name instead and cannot be called.
    private var callableNumber: String? {
        guard conversation.participants.count == 1 else { return nil }
        let address = conversation.participants[0]
        let digits = address.filter(\.isNumber).count
        let allowed = address.allSatisfy { $0.isNumber || " +-()./".contains($0) }
        return allowed && digits >= 3 ? address : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ContactAvatar(name: model.title(for: conversation), photo: model.contact(for: conversation)?.photo,
                              isGroup: conversation.participants.count > 1, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.title(for: conversation)).fontWeight(.semibold).lineLimit(1)
                    // Under a contact's name, the number the texts go to.
                    if conversation.participants.count == 1, model.contacts.name(for: conversation.participants[0]) != nil {
                        Text(conversation.participants[0]).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Text Message").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let dialNotice { Text(dialNotice).font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.trailing) }
                if let number = callableNumber {
                    Button {
                        Task { @MainActor in
                            let problem = await model.actions?.dialOnPhone(number)
                            dialNotice = problem ?? "The phone's dialer is open. Press call there."
                            try? await Task.sleep(for: .seconds(8))
                            dialNotice = nil
                        }
                    } label: { Image(systemName: "phone.fill") }
                        .buttonStyle(.bordered).buttonBorderShape(.circle)
                        .help("Open the phone's dialer with this number")
                        .accessibilityLabel("Call \(model.title(for: conversation)) on phone")
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(conversation.messages.enumerated()), id: \.element.id) { index, message in
                            let placement = MessagesFormat.placement(of: index, in: conversation.messages)
                            if placement.showsTime {
                                Text(MessagesFormat.separator(message.date)).font(.caption).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity).padding(.top, index == 0 ? 4 : 14).padding(.bottom, 6)
                            }
                            VStack(alignment: message.isIncoming ? .leading : .trailing, spacing: 3) {
                                ForEach(message.attachments) { attachment in
                                    HStack {
                                        if !message.isIncoming { Spacer(minLength: 60) }
                                        AttachmentView(attachment: attachment, model: model)
                                        if message.isIncoming { Spacer(minLength: 60) }
                                    }
                                }
                                // Attachments the phone has only counted, not described: ask for them.
                                if message.attachments.isEmpty, message.attachmentCount > 0 {
                                    HStack {
                                        if !message.isIncoming { Spacer(minLength: 60) }
                                        UndescribedAttachments(message: message, model: model)
                                        if message.isIncoming { Spacer(minLength: 60) }
                                    }
                                }
                                let text = message.body
                                if !text.isEmpty || (message.attachments.isEmpty && message.attachmentCount == 0) {
                                    Bubble(text: text, outgoing: !message.isIncoming)
                                        .help(message.date.formatted(date: .abbreviated, time: .shortened))
                                }
                            }
                            // Close under the one before when they belong together.
                            .padding(.top, placement.showsTime ? 0 : placement.joins ? 2 : 8)
                            .id(message.id)
                        }
                        ForEach(conversation.pending) { pending in
                            PendingBubble(pending: pending) { model.actions?.discardFailedMessage(pending.id) }
                                .padding(.top, 8)
                                .id("pending-\(pending.id)")
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: conversation.messages.count + conversation.pending.count) { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: conversation.id) { proxy.scrollTo("end", anchor: .bottom) }
            }
            Divider()
            if !attached.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(attached.enumerated()), id: \.offset) { index, file in
                            ZStack(alignment: .topTrailing) {
                                if let image = NSImage(data: file.data) {
                                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).frame(width: 56, height: 56)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                Button { attached.remove(at: index) } label: {
                                    Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.6))
                                }
                                .buttonStyle(.plain).padding(2)
                                .accessibilityLabel("Remove picture \(file.name)")
                            }
                        }
                        Text("Sent as a picture message; your mobile plan's rates apply.").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10).padding(.top, 8)
                }
            }
            if let attachProblem {
                Text(attachProblem).font(.caption).foregroundStyle(.orange).padding(.horizontal, 10).padding(.top, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button(action: choosePictures) { Image(systemName: "plus.circle.fill").font(.system(size: 24)).symbolRenderingMode(.hierarchical) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Attach pictures")
                    .accessibilityLabel("Attach pictures")
                    .padding(.bottom, 2)
                // The field and its send button in one rounded frame, as in Messages.
                HStack(alignment: .bottom, spacing: 4) {
                    TextField("Text Message", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...5)
                        .onSubmit(send)
                        .padding(.leading, 12).padding(.vertical, 6)
                    Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 22)) }
                        .buttonStyle(.plain).foregroundStyle(canSend ? Bubble.sentColor : Color.secondary.opacity(0.5))
                        .disabled(!canSend).keyboardShortcut(.return, modifiers: .command)
                        .help("Send from your phone's number")
                        .accessibilityLabel("Send")
                        .padding(3)
                }
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.quaternary, lineWidth: 1))
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
    }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attached.isEmpty }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attached.isEmpty else { return }
        model.actions?.sendMessage(text, attachments: attached, in: conversation)
        draft = ""
        attached = []
        attachProblem = nil
    }

    /// Lets the user pick pictures. Each is re-encoded small enough for a picture message,
    /// which carriers cap at well under a megabyte, and stripped of everything but pixels.
    private func choosePictures() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = "Choose pictures to send"
        guard panel.runModal() == .OK else { return }
        attachProblem = nil
        let room = max(0, OutgoingPicture.maxCount - attached.count)
        for url in panel.urls.prefix(room) {
            if let picture = OutgoingPicture.make(from: url) { attached.append(picture) } else { attachProblem = "\(url.lastPathComponent) could not be read as a picture." }
        }
        if panel.urls.count > room, attachProblem == nil {
            attachProblem = "A message carries at most \(OutgoingPicture.maxCount) pictures; the rest were left out."
        }
    }
}

struct Bubble: View {
    let text: String
    let outgoing: Bool
    var footnote: String?
    var dimmed = false

    /// These are texts sent through the phone's number, which Messages shows in green.
    static let sentColor = Color.green

    var body: some View {
        HStack(spacing: 0) {
            if outgoing { Spacer(minLength: 80) }
            VStack(alignment: outgoing ? .trailing : .leading, spacing: 2) {
                Text(text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(outgoing ? AnyShapeStyle(Bubble.sentColor) : AnyShapeStyle(.quaternary), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                    .foregroundStyle(outgoing ? Color.white : Color.primary)
                    .opacity(dimmed ? 0.55 : 1)
                if let footnote { Text(footnote).font(.caption2).foregroundStyle(.secondary) }
            }
            if !outgoing { Spacer(minLength: 80) }
        }
    }
}

struct PendingBubble: View {
    let pending: PendingMessage
    let discard: () -> Void

    /// The text, or a word for the pictures when they go without any.
    private var text: String {
        let pictures = pending.attachmentCount == 1 ? "Picture" : "\(pending.attachmentCount) pictures"
        if pending.attachmentCount == 0 { return pending.body }
        return pending.body.isEmpty ? pictures : "\(pending.body)\n\(pictures)"
    }

    var body: some View {
        switch pending.state {
        case .sending:
            Bubble(text: text, outgoing: true, footnote: "Sending…", dimmed: true)
        case .failed(let reason):
            VStack(alignment: .trailing, spacing: 2) {
                Bubble(text: text, outgoing: true, dimmed: true)
                HStack(spacing: 6) {
                    Label(MessageSync.describeFailure(reason), systemImage: "exclamationmark.circle.fill")
                        .font(.caption).foregroundStyle(.red)
                    Button("Remove", action: discard).buttonStyle(.link).font(.caption)
                }
            }
        }
    }
}

/// A sheet to start a conversation with a phone number.
struct NewMessageView: View {
    var contacts = ContactBook()
    let send: (String, String) -> Void
    let cancel: () -> Void
    @State private var number: String
    @State private var text = ""

    /// - Parameter number: who the message is for, when that is already known.
    init(contacts: ContactBook = ContactBook(), number: String = "", send: @escaping (String, String) -> Void, cancel: @escaping () -> Void) {
        self.contacts = contacts
        self.send = send
        self.cancel = cancel
        _number = State(initialValue: number)
    }

    private var ready: Bool {
        !number.trimmingCharacters(in: .whitespaces).isEmpty && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Message").font(.headline)
            TextField(contacts.isEmpty ? "Phone number" : "Name or phone number", text: $number).textFieldStyle(.roundedBorder)
            // Typing a name offers that contact's numbers; choosing one fills the field.
            let matches = contacts.recipients(matching: number).filter { $0.number != number }
            if !matches.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(matches) { match in
                            Button { number = match.number } label: {
                                HStack(spacing: 8) {
                                    ContactAvatar(name: match.contact.name, photo: match.contact.photo, size: 22)
                                    Text(match.contact.name)
                                    Spacer()
                                    Text(match.number).foregroundStyle(.secondary).monospacedDigit()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 2)
                        }
                    }
                }
                .frame(maxHeight: 132)
            }
            TextField("Text message", text: $text, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(3...6)
            Text("Sent from your phone's number. Your carrier may charge for it.").font(.footnote).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button("Send") { send(number.trimmingCharacters(in: .whitespaces), text.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    .keyboardShortcut(.defaultAction).disabled(!ready)
            }
        }
        .padding(18)
        .frame(width: 380)
    }
}

/// A picture message of which only the number of attachments is known. Clicking asks the
/// phone what they are; they then show as attachments of their own.
struct UndescribedAttachments: View {
    let message: PhoneMessage
    @ObservedObject var model: AppModel
    @State private var loading = false
    @State private var failed = false

    var body: some View {
        Button {
            guard !loading else { return }
            loading = true
            failed = false
            Task { @MainActor in
                let answered = await model.actions?.loadAttachmentList(of: message) ?? false
                loading = false
                failed = !answered
            }
        } label: {
            HStack(spacing: 8) {
                if loading { ProgressView().controlSize(.small) } else { Image(systemName: failed ? "exclamationmark.triangle" : "paperclip") }
                VStack(alignment: .leading, spacing: 1) {
                    Text(message.attachmentCount == 1 ? "Attachment" : "\(message.attachmentCount) attachments")
                    Text(failed ? "The phone did not answer. Click to try again." : loading ? "Asking the phone…" : "Click to load")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(Color(nsColor: .quaternaryLabelColor), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(loading)
    }
}

/// One file of a picture message. A picture whose bytes have been seen shows as a preview;
/// anything else as a chip that fetches the file from the phone when clicked, as Phone Link
/// does, and then opens it.
struct AttachmentView: View {
    let attachment: MessageAttachment
    @ObservedObject var model: AppModel
    @State private var loading = false
    @State private var failed = false

    static func symbol(for type: String) -> String {
        let type = type.lowercased()
        if type.hasPrefix("image/") { return "photo" }
        if type.hasPrefix("video/") { return "film" }
        if type.hasPrefix("audio/") { return "waveform" }
        if type.contains("vcard") { return "person.crop.rectangle" }
        return "doc"
    }

    static func kind(of type: String) -> String {
        let type = type.lowercased()
        if type.hasPrefix("image/") { return "Picture" }
        if type.hasPrefix("video/") { return "Video" }
        if type.hasPrefix("audio/") { return "Audio" }
        if type.contains("vcard") { return "Contact card" }
        return "File"
    }

    private var sizeText: String? {
        attachment.size > 0 ? ByteCountFormatter.string(fromByteCount: attachment.size, countStyle: .file) : nil
    }

    var body: some View {
        Group {
            if let preview = attachment.preview, let image = NSImage(data: preview) {
                Button { fetch(thenOpen: true) } label: {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 240, maxHeight: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay { if loading { ProgressView().controlSize(.small).padding(6).background(.regularMaterial, in: Circle()) } }
                }
                .buttonStyle(.plain)
                .help("Open the picture")
                .accessibilityLabel("Picture\(attachment.name.isEmpty ? "" : ", " + attachment.name). Opens the full picture.")
            } else {
                Button { fetch(thenOpen: !attachment.isImage) } label: {
                    HStack(spacing: 8) {
                        if loading { ProgressView().controlSize(.small) } else { Image(systemName: failed ? "exclamationmark.triangle" : AttachmentView.symbol(for: attachment.contentType)) }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(attachment.name.isEmpty ? AttachmentView.kind(of: attachment.contentType) : attachment.name).lineLimit(1)
                            Text(failed ? "The phone did not send it. Click to try again."
                                 : [sizeText, loading ? "Loading from the phone…" : (attachment.isImage ? "Click to load" : "Click to open")].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 11).padding(.vertical, 8)
                    .background(Color(nsColor: .quaternaryLabelColor), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(loading)
            }
        }
        .contextMenu {
            Button("Open") { fetch(thenOpen: true) }
            Button("Save As…") { fetch(thenOpen: false, thenSave: true) }
        }
    }

    /// Gets the file from the phone. For a picture that alone makes its preview appear, since
    /// the bytes arrive through the message sync.
    private func fetch(thenOpen: Bool, thenSave: Bool = false) {
        guard !loading else { return }
        loading = true
        failed = false
        Task { @MainActor in
            let data = await model.actions?.fetchAttachment(attachment)
            loading = false
            guard let data else { failed = true; return }
            // A picture loads into the thread by itself once its bytes are here. One this Mac
            // cannot draw would stay a chip for ever, so it is offered like any other file.
            let unshowable = attachment.isImage && attachment.preview == nil && PhotoSync.makeThumbnail(from: data, commonFormatsOnly: true) == nil
            if thenSave {
                save(data)
            } else if thenOpen || unshowable {
                // Only kinds that are viewed, never run, are handed to another app; anything
                // else can be saved, where the user decides what to do with it.
                if AttachmentFiles.isSafeToOpen(attachment), let url = AttachmentFiles.write(data, named: AttachmentFiles.fileName(for: attachment)) {
                    NSWorkspace.shared.open(url)
                } else {
                    save(data)
                }
            }
        }
    }

    /// Asks where to save, without holding up the rest of the app while the panel is open.
    private func save(_ data: Data) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = AttachmentFiles.fileName(for: attachment)
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.begin { response in
            if response == .OK, let url = panel.url { AttachmentFiles.save(data, to: url) }
        }
    }
}

/// Temporary copies of attachments opened in other apps. They hold message content, so they
/// are removed at launch and at sign-out.
enum AttachmentFiles {
    static var folder: URL { FileManager.default.temporaryDirectory.appendingPathComponent("phone-mac-link-attachments", isDirectory: true) }

    /// The phone's file name reduced to a plain name: no folders, no leading dot.
    static func safeName(_ name: String) -> String {
        var cleaned = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "\\", with: "_")
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        return cleaned.isEmpty ? "attachment" : String(cleaned.prefix(120))
    }

    /// The type the phone declares for the attachment.
    static func type(of attachment: MessageAttachment) -> UTType? {
        UTType(mimeType: attachment.contentType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "")
    }

    /// The kinds that may be handed to another app: each is shown by the app that opens it
    /// and can neither run anything nor send the app elsewhere. Named one by one, because
    /// "any picture" includes SVG and "any audio or text" includes playlists and stream
    /// descriptions, which make a player contact hosts the sender chose.
    static let openableTypes: Set<String> = [
        "public.jpeg", "public.png", "com.compuserve.gif", "public.heic", "public.heif", "org.webmproject.webp", "public.tiff",
        "com.microsoft.bmp",
        "public.mpeg-4", "com.apple.quicktime-movie", "public.3gpp", "public.3gpp2",
        "public.mp3", "public.mpeg-4-audio", "com.apple.m4a-audio", "com.microsoft.waveform-audio", "public.aiff-audio",
        "org.3gpp.adaptive-multi-rate-audio",
        "com.adobe.pdf", "public.vcard", "public.plain-text", "public.utf8-plain-text",
    ]

    /// Extensions a saved file may keep when its declared type says nothing.
    static let harmlessExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "bmp", "tif", "tiff", "mp4", "m4v", "mov",
                                                  "3gp", "3g2", "mp3", "m4a", "wav", "aif", "aiff", "amr", "ogg", "pdf", "vcf", "txt"]

    /// Whether the attachment is opened from here. Anything else from a message is only ever
    /// saved: a sender chooses the file and its name.
    static func isSafeToOpen(_ attachment: MessageAttachment) -> Bool {
        guard let type = type(of: attachment) else { return false }
        return openableTypes.contains(type.identifier)
    }

    /// The name to store the file under. Its extension follows the declared type, not the
    /// name the sender gave, so a file cannot pose as another kind; a file of no known type
    /// keeps its extension only when that is a harmless one.
    static func fileName(for attachment: MessageAttachment) -> String {
        let name = safeName(attachment.fileName)
        let given = (name as NSString).pathExtension.lowercased()
        guard let declared = type(of: attachment), !declared.isDynamic, let wanted = declared.preferredFilenameExtension else {
            return harmlessExtensions.contains(given) ? name : name + ".download"
        }
        // "jpg" for a JPEG is as good as "jpeg".
        if !given.isEmpty, UTType(filenameExtension: given) == declared { return name }
        let base = (name as NSString).deletingPathExtension
        return (base.isEmpty ? "attachment" : base) + "." + wanted
    }

    /// Marks a file as having come from outside, as a browser does for a download, so that
    /// macOS checks it before it is first opened.
    static func quarantine(_ url: URL) {
        var values = URLResourceValues()
        values.quarantineProperties = [kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
                                       kLSQuarantineAgentNameKey as String: "Phone Mac Link"]
        var target = url
        try? target.setResourceValues(values)
    }

    /// Writes an attachment where the user chose, marked as a download.
    static func save(_ data: Data, to url: URL) {
        guard (try? data.write(to: url, options: [.atomic])) != nil else { return }
        quarantine(url)
    }

    static func write(_ data: Data, named name: String) -> URL? {
        let directory = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = directory.appendingPathComponent(safeName(name))
            try data.write(to: url, options: [.atomic])
            quarantine(url)
            return url
        } catch {
            return nil
        }
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: folder)
    }
}

/// Prepares a picture for sending in a picture message.
enum OutgoingPicture {
    /// What a picture is shrunk to. Carriers refuse larger messages; many cap at 300 KB to 1 MB.
    static let byteLimit = 280 * 1024
    /// Two at that size stay under what most carriers accept for one message.
    static let maxCount = 2

    /// Reads an image file and re-encodes it as a JPEG within the limit. Re-encoding also
    /// drops location and camera details stored in the file.
    static func make(from url: URL) -> OutgoingAttachment? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return make(from: data, name: url.deletingPathExtension().lastPathComponent)
    }

    static func make(from data: Data, name: String) -> OutgoingAttachment? {
        var side = 1600
        while side >= 320 {
            for quality in [0.8, 0.65, 0.5] {
                if let jpeg = PhotoSync.makeThumbnail(from: data, maxPixelSize: side, quality: quality), jpeg.count <= byteLimit {
                    return OutgoingAttachment(name: AttachmentFiles.safeName(name) + ".jpg", contentType: "image/jpeg", data: jpeg)
                }
            }
            side = side * 3 / 4
        }
        return nil
    }
}
