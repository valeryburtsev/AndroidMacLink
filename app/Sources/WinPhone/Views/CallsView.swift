import SwiftUI
import WinPhoneCore

/// The phone's recent calls, by day, as the phone's own list shows them. A call can be started
/// from here only as far as the phone allows over this link: its dialer opens with the
/// number, and the user presses call there.
struct CallsView: View {
    @ObservedObject var model: AppModel
    @State private var notice: String?
    @State private var noticeIsProblem = false
    @State private var filter = Filter.all

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", missed = "Missed"
        var id: Filter { self }
    }

    /// Calls in a row with one number and one outcome, shown as a single entry with a count.
    struct Entry: Identifiable, Equatable {
        var calls: [PhoneCall]
        var newest: PhoneCall { calls[0] }
        var id: Int64 { newest.id }
    }

    struct Day: Identifiable, Equatable {
        var id: Date
        var title: String
        var entries: [Entry]
    }

    /// Splits calls, newest first, into days, and joins repeats within a day.
    static func days(_ calls: [PhoneCall], now: Date = Date(), calendar: Calendar = .current) -> [Day] {
        var days: [Day] = []
        for call in calls.sorted(by: { $0.date > $1.date }) {
            let start = calendar.startOfDay(for: call.date)
            if days.last?.id != start { days.append(Day(id: start, title: dayTitle(start, now: now, calendar: calendar), entries: [])) }
            let day = days.count - 1
            if let last = days[day].entries.last, !call.number.isEmpty, last.newest.number == call.number, last.newest.kind == call.kind {
                days[day].entries[days[day].entries.count - 1].calls.append(call)
            } else {
                days[day].entries.append(Entry(calls: [call]))
            }
        }
        return days
    }

    static func dayTitle(_ day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let age = calendar.dateComponents([.day], from: day, to: calendar.startOfDay(for: now)).day ?? 0
        switch age {
        case 0: return "Today"
        case 1: return "Yesterday"
        case 2..<7: return day.formatted(.dateTime.weekday(.wide))
        default: return day.formatted(calendar.isDate(day, equalTo: now, toGranularity: .year) ? .dateTime.month(.wide).day() : .dateTime.month(.wide).day().year())
        }
    }

    private var shown: [PhoneCall] {
        filter == .missed ? model.calls.filter { $0.kind == .missed } : model.calls
    }

    var body: some View {
        VStack(spacing: 12) {
            if let notice {
                HStack(spacing: 10) {
                    Image(systemName: noticeIsProblem ? "exclamationmark.triangle.fill" : "iphone.gen3.radiowaves.left.and.right")
                        .foregroundStyle(noticeIsProblem ? AnyShapeStyle(.orange) : AnyShapeStyle(.tint))
                    Text(notice).font(.callout)
                    Spacer()
                    Button { self.notice = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .buttonStyle(.borderless).accessibilityLabel("Dismiss")
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .card()
            }
            if model.liveCall != nil {
                LiveCallBar(model: model)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .card()
            }
            // The history and the dial pad, each on a card of its own.
            HStack(spacing: 12) {
                content.frame(maxWidth: .infinity, maxHeight: .infinity).card()
                DialPad(model: model) { number, name in dial(number, name: name) }
                    .frame(width: 264)
                    .frame(maxHeight: .infinity)
                    .card()
            }
        }
        .pageInset()
        .navigationTitle("Calls")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Show every call or only the missed ones")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.actions?.refreshCalls() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Ask the phone for its call history again")
                    .disabled(!model.callsEnabled)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if !model.callsEnabled {
            EmptyState(title: "No Call History", symbol: "phone", tint: SidebarItem.calls.tint, message: "Calls to your phone show on screen while they ring. To see the phone's call history here, turn on Recent calls in Settings.")
        } else if model.callLogAccessMissing {
            EmptyState(title: "Call history access is off", symbol: "phone.badge.checkmark", tint: .orange, message: "On the phone, open Link to Windows and allow it to read the call log.")
        } else if model.calls.isEmpty {
            EmptyState(title: "No Recent Calls", symbol: "phone", tint: SidebarItem.calls.tint, message: "Calls of the last 30 days on your phone appear here.")
        } else if shown.isEmpty {
            EmptyState(title: "No Missed Calls", symbol: "phone.arrow.down.left", tint: SidebarItem.calls.tint, message: "Nothing was missed in the last 30 days.")
        } else {
            List {
                ForEach(CallsView.days(shown)) { day in
                    Section(day.title) {
                        ForEach(day.entries) { entry in
                            let call = entry.newest
                            CallRow(call: call, count: entry.calls.count, title: model.title(for: call),
                                    photo: call.number.isEmpty ? nil : model.contacts.contact(for: call.number)?.photo) {
                                dial(call.number, name: model.title(for: call))
                            }
                            .contextMenu {
                                if !call.number.isEmpty {
                                    Button(model.canPlaceCalls ? "Call" : "Call on Phone") { dial(call.number, name: model.title(for: call)) }
                                    Button("Copy Number") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(call.number, forType: .string)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func dial(_ number: String, name: String) {
        guard !number.isEmpty else { return }
        // Over Bluetooth the call is placed at once; what happens next shows in the call bar.
        if model.canPlaceCalls, model.actions?.placeCall(number) == true {
            notice = nil
            return
        }
        Task { @MainActor in
            if let problem = await model.actions?.dialOnPhone(number) {
                notice = problem
                noticeIsProblem = true
            } else {
                notice = "Your phone's dialer is open with \(name). Press call on the phone."
                noticeIsProblem = false
            }
        }
    }
}

/// A keypad with a field above it: a number typed or tapped in, or a contact found by name.
/// During a call its keys send their tones.
struct DialPad: View {
    @ObservedObject var model: AppModel
    let dial: (_ number: String, _ name: String) -> Void
    @State private var entry = ""

    static let keys: [[(key: Character, letters: String)]] = [
        [("1", ""), ("2", "ABC"), ("3", "DEF")],
        [("4", "GHI"), ("5", "JKL"), ("6", "MNO")],
        [("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ")],
        [("*", ""), ("0", "+"), ("#", "")],
    ]

    /// What can be dialled as typed: digits with the usual signs around them.
    static func number(in entry: String) -> String? {
        let text = entry.trimmingCharacters(in: .whitespaces)
        guard text.contains(where: \.isNumber), text.allSatisfy({ $0.isNumber || "+*#-() ".contains($0) }) else { return nil }
        return text
    }

    private var inCall: Bool { model.liveCall?.phase == .active }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                TextField(model.contacts.isEmpty ? "Number" : "Name or number", text: $entry)
                    .textFieldStyle(.plain).font(.title3).monospacedDigit()
                    .onSubmit { call() }
                if !entry.isEmpty {
                    Button { entry.removeLast() } label: { Image(systemName: "delete.left.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).help("Delete").accessibilityLabel("Delete")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            let matches = model.contacts.recipients(matching: entry, limit: 3)
            if !matches.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(matches) { match in
                        Button { entry = ""; dial(match.number, match.contact.name) } label: {
                            HStack(spacing: 8) {
                                ContactAvatar(name: match.contact.name, photo: match.contact.photo, size: 24)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(match.contact.name).lineLimit(1)
                                    Text(match.number).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Call \(match.contact.name)")
                    }
                }
            }
            Grid(horizontalSpacing: 14, verticalSpacing: 10) {
                ForEach(DialPad.keys, id: \.first?.key) { row in
                    GridRow {
                        ForEach(row, id: \.key) { item in
                            Button { press(item.key) } label: {
                                VStack(spacing: 0) {
                                    // The star as typed sits above the line of the digits.
                                    if item.key == "*" {
                                        Image(systemName: "asterisk").font(.body.weight(.semibold)).frame(height: 26)
                                    } else {
                                        Text(String(item.key)).font(.title2.weight(.medium))
                                    }
                                    Text(item.letters).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).frame(height: 10)
                                }
                                .frame(width: 58, height: 58)
                                .background(.quaternary.opacity(0.7), in: Circle())
                                .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(item.key == "*" ? "Star" : item.key == "#" ? "Hash" : String(item.key))
                        }
                    }
                }
            }
            Button(action: call) {
                Image(systemName: "phone.fill").font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 58, height: 58)
                    .background(Color.green.opacity(DialPad.number(in: entry) == nil || model.liveCall != nil ? 0.4 : 1), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(DialPad.number(in: entry) == nil || model.liveCall != nil)
            .help(model.canPlaceCalls ? "Call" : "Open the phone's dialer with this number")
            .accessibilityLabel("Call")
            Text(model.canPlaceCalls ? "Calls are placed by your phone." : "Opens the phone's dialer. Press call there, or turn on Calls on this Mac in Settings.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(minWidth: 200).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private func press(_ key: Character) {
        // In a call the key is for the other side: a menu to answer, a code to enter.
        if inCall { model.actions?.callTone(key) }
        entry.append(key)
    }

    private func call() {
        guard model.liveCall == nil, let number = DialPad.number(in: entry) else { return }
        entry = ""
        dial(number, number)
    }
}

struct CallRow: View {
    let call: PhoneCall
    /// How many calls in a row this entry stands for.
    var count = 1
    let title: String
    var photo: Data?
    let dial: () -> Void
    @State private var hovering = false

    static func symbol(_ kind: PhoneCall.Kind) -> String {
        switch kind {
        case .incoming: return "phone.arrow.down.left"
        case .outgoing: return "phone.arrow.up.right"
        case .missed: return "phone.arrow.down.left"
        case .declined: return "phone.down"
        case .blocked: return "hand.raised"
        case .unknown: return "phone"
        }
    }

    static func label(_ kind: PhoneCall.Kind) -> String {
        switch kind {
        case .incoming: return "Incoming"
        case .outgoing: return "Outgoing"
        case .missed: return "Missed"
        case .declined: return "Declined"
        case .blocked: return "Blocked"
        case .unknown: return "Call"
        }
    }

    static func duration(_ seconds: Int64) -> String? {
        guard seconds > 0 else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: TimeInterval(seconds))
    }

    private var detail: String {
        var parts = [CallRow.label(call.kind)]
        if let length = CallRow.duration(call.duration) { parts.append(length) }
        // Under a contact's name, the number the call was with.
        if title != call.number, !call.number.isEmpty { parts.append(call.number) }
        return parts.joined(separator: " · ")
    }

    private var missed: Bool { call.kind == .missed }

    var body: some View {
        HStack(spacing: 12) {
            ContactAvatar(name: title, photo: photo, isGroup: false, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(title).lineLimit(1)
                        .foregroundStyle(missed ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                    if count > 1 { Text("(\(count))").foregroundStyle(.secondary) }
                }
                HStack(spacing: 4) {
                    Image(systemName: CallRow.symbol(call.kind)).font(.caption2.weight(.semibold))
                    Text(detail).lineLimit(1)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if hovering, !call.number.isEmpty {
                Button(action: dial) { Image(systemName: "phone.circle.fill").font(.title2) }
                    .buttonStyle(.borderless).foregroundStyle(.green)
                    .help("Open the phone's dialer with this number")
                    .accessibilityLabel("Call \(title) on phone")
            } else {
                Text(call.date.formatted(date: .omitted, time: .shortened)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.vertical, 4)
        .frame(minHeight: 40)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(CallRow.label(call.kind)) call, \(title)\(count > 1 ? ", \(count) times" : ""), \(MessagesFormat.short(call.date))")
        .accessibilityAction(named: "Call on phone") { if !call.number.isEmpty { dial() } }
    }
}
