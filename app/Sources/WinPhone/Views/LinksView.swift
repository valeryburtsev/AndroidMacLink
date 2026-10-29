import SwiftUI
import WinPhoneCore

/// Links across the two devices: open the ones that came from the phone, and, while that is
/// switched on (`AppModel.linkSendingEnabled`), send one from this Mac to the phone.
struct LinksView: View {
    @ObservedObject var model: AppModel
    @State private var entry = ""
    @State private var dropTargeted = false

    /// The web address on this Mac's clipboard, if that is what was copied.
    static func linkOnMacClipboard() -> URL? {
        NSPasteboard.general.string(forType: .string).flatMap(PhoneLinks.webURL)
    }

    private var typed: URL? {
        let text = entry.trimmingCharacters(in: .whitespaces)
        if let url = PhoneLinks.webURL(text) { return url }
        // "example.com/page" is meant as a web address too.
        return text.contains(".") && !text.contains(" ") ? PhoneLinks.webURL("https://" + text) : nil
    }

    private var canSend: Bool { model.isConnected && model.fileTransferStatus == nil }

    var body: some View {
        Form {
            if AppModel.linkSendingEnabled {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "link").foregroundStyle(.secondary)
                        TextField("Web address", text: $entry, prompt: Text("Paste or type a web address"))
                            .textFieldStyle(.plain).labelsHidden()
                            .onSubmit(send)
                        if entry.isEmpty, let copied = LinksView.linkOnMacClipboard() {
                            Button("Paste") { entry = copied.absoluteString }.buttonStyle(.link)
                        }
                        Button("Send to Phone", action: send)
                            .buttonStyle(.borderedProminent)
                            .disabled(typed == nil || !canSend)
                    }
                    if let notice = model.linkNotice {
                        Text(notice).font(.callout).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("To the Phone")
                } footer: {
                    Text("The phone shows a notification; tapping it opens the page in the phone's browser. Also in the menu bar item, and in any app under Services after selecting a link.")
                        .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Section {
                if model.phoneLinks.isEmpty {
                    Text("Copy a link on the phone, or in its share sheet choose Copy, and it shows here ready to open.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.phoneLinks) { link in
                    HStack(spacing: 12) {
                        Image(systemName: link.source == .copied ? "doc.on.doc" : "safari")
                            .font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 28, height: 28)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(link.title).lineLimit(1)
                            Text("\(link.caption) · \(link.date.formatted(date: .omitted, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Button("Open") { NSWorkspace.shared.open(link.url) }
                    }
                    .contextMenu {
                        Button("Open") { NSWorkspace.shared.open(link.url) }
                        Button("Copy Link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(link.url.absoluteString, forType: .string)
                        }
                    }
                }
            } header: {
                Text("From the Phone")
            } footer: {
                Text("Links copied on the phone, and pages open in a browser there that supports \"continue on PC\". How they are announced is in Settings, General.")
                    .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        // The whole page on one card, its groups inside as before.
        .scrollContentBackground(.hidden)
        .card()
        .pageInset()
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14).fill(Color.accentColor.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7, 5])))
                    .overlay(Label("Send Link to Phone", systemImage: "link.circle.fill").font(.title2.weight(.semibold)).foregroundStyle(.tint))
                    .padding(10).allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard AppModel.linkSendingEnabled, canSend, let url = urls.compactMap({ PhoneLinks.webURL($0.absoluteString) }).first else { return false }
            model.actions?.sendLink(url)
            return true
        } isTargeted: { dropTargeted = $0 && canSend && AppModel.linkSendingEnabled }
        .navigationTitle("Links")
    }

    private func send() {
        guard let url = typed, canSend else { return }
        model.actions?.sendLink(url)
        entry = ""
    }
}
