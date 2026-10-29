import SwiftUI
import WinPhoneCore

/// The phone's contacts: the list by name on the left, the chosen one on the right with a way
/// to write to or call each of its numbers.
struct ContactsView: View {
    @ObservedObject var model: AppModel
    @State private var selected: Int64?
    @State private var search = ""
    @State private var notice: String?

    /// Contacts that have a name, by name, narrowed by the search words.
    static func listed(_ book: ContactBook, search: String) -> [PhoneContact] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let digits = query.filter(\.isNumber)
        return book.contacts.values
            .filter { !$0.name.isEmpty }
            .filter { contact in
                guard !query.isEmpty else { return true }
                if contact.name.localizedCaseInsensitiveContains(query) || contact.company.localizedCaseInsensitiveContains(query) { return true }
                return digits.count >= 3 && (book.numbersByContact[contact.id] ?? []).contains { $0.filter(\.isNumber).contains(digits) }
            }
            // As an address book orders names: accents with their letters, case set aside.
            .sorted {
                let order = $0.name.localizedStandardCompare($1.name)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
    }

    /// The letter a name is filed under; anything that does not start with one goes under "#".
    static func initial(_ name: String) -> String {
        guard let first = name.trimmingCharacters(in: .whitespaces).first, first.isLetter else { return "#" }
        return String(first).folding(options: .diacriticInsensitive, locale: .current).uppercased()
    }

    static func sections(_ contacts: [PhoneContact]) -> [(letter: String, contacts: [PhoneContact])] {
        var result: [(letter: String, contacts: [PhoneContact])] = []
        for contact in contacts {
            let letter = initial(contact.name)
            if result.last?.letter == letter { result[result.count - 1].contacts.append(contact) } else { result.append((letter, [contact])) }
        }
        // "#" last, as address books have it.
        return result.filter { $0.letter != "#" } + result.filter { $0.letter == "#" }
    }

    private var listed: [PhoneContact] { ContactsView.listed(model.contacts, search: search) }
    /// The chosen contact, or the one at the top of the list as it is shown.
    private var current: PhoneContact? { listed.first { $0.id == selected } ?? ContactsView.sections(listed).first?.contacts.first }

    var body: some View {
        Group {
            if model.contacts.isEmpty {
                EmptyState(title: "No Contacts", symbol: "person.crop.circle", tint: SidebarItem.contacts.tint, message: "The phone's contacts appear here once it has sent them. On the phone, Link to Windows needs access to contacts.")
            } else {
                // Two cards side by side: the list, and the contact.
                HStack(spacing: 12) {
                    VStack(spacing: 0) {
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
                            ForEach(ContactsView.sections(listed), id: \.letter) { section in
                                Section(section.letter) {
                                    ForEach(section.contacts) { contact in
                                        HStack(spacing: 10) {
                                            ContactAvatar(name: contact.name, photo: contact.photo, size: 28)
                                            Text(contact.name).lineLimit(1)
                                        }
                                        .padding(.vertical, 1)
                                        .tag(contact.id)
                                    }
                                }
                            }
                        }
                        .listStyle(.inset)
                        .overlay { if listed.isEmpty { ContentUnavailableView.search(text: search) } }
                    }
                    .frame(width: 280)
                    .card()
                    Group {
                        if let contact = current {
                            ContactDetail(model: model, contact: contact, notice: $notice)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .card()
                }
                .pageInset()
            }
        }
        .navigationTitle("Contacts")
        .sectionSubtitle(model.contacts.isEmpty ? "" : "\(ContactsView.listed(model.contacts, search: "").count) on the phone")
    }
}

/// One contact: who it is, and its numbers with what can be done with each.
private struct ContactDetail: View {
    @ObservedObject var model: AppModel
    let contact: PhoneContact
    @Binding var notice: String?

    private var numbers: [String] { model.contacts.numbersByContact[contact.id] ?? [] }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ContactAvatar(name: contact.name, photo: contact.photo, size: 96)
                    .padding(.top, 36)
                Text(contact.name).font(.title.weight(.semibold)).multilineTextAlignment(.center)
                    .padding(.top, 14)
                if !contact.company.isEmpty, contact.company != contact.name {
                    Text(contact.company).font(.title3).foregroundStyle(.secondary).padding(.top, 2)
                }
                VStack(spacing: 0) {
                    if numbers.isEmpty {
                        Text("No phone number").foregroundStyle(.secondary).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(Array(numbers.enumerated()), id: \.offset) { index, number in
                        if index > 0 { Divider().padding(.leading, 14) }
                        HStack(spacing: 10) {
                            Text(number).monospacedDigit().textSelection(.enabled)
                            Spacer(minLength: 12)
                            Button { model.messageTarget = number; model.selection = .messages } label: {
                                Image(systemName: "message.fill")
                            }
                            .help("Write a text message").accessibilityLabel("Message \(contact.name)")
                            Button { call(number) } label: { Image(systemName: "phone.fill") }
                                .help(model.canPlaceCalls ? "Call" : "Open the phone's dialer with this number")
                                .accessibilityLabel("Call \(contact.name)")
                                .disabled(model.liveCall != nil)
                        }
                        .buttonStyle(.bordered).buttonBorderShape(.circle)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                    }
                }
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .frame(maxWidth: 420)
                .padding(.top, 26).padding(.horizontal, 24)
                if let notice {
                    Text(notice).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .frame(minWidth: 240, maxWidth: 420).fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 14)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 24)
        }
        .onChange(of: contact.id) { _, _ in notice = nil }
    }

    private func call(_ number: String) {
        // Over Bluetooth the call is placed at once and shows in its own panel.
        if model.canPlaceCalls, model.actions?.placeCall(number) == true {
            notice = nil
            return
        }
        Task { @MainActor in
            if let problem = await model.actions?.dialOnPhone(number) {
                notice = problem
            } else {
                notice = "Your phone's dialer is open with \(contact.name). Press call on the phone."
            }
        }
    }
}
