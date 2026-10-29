import SwiftUI
import WinPhoneCore

/// One screen of the way in: a symbol on a tile, what the step is, what to do, and the
/// controls for it, set in the middle of the window like the system's own setup screens.
struct OnboardingPage<Content: View>: View {
    let symbol: String
    var tint = Color.accentColor
    let title: String
    var message: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .medium)).foregroundStyle(.white)
                .frame(width: 76, height: 76)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
                .shadow(color: tint.opacity(0.25), radius: 12, y: 5)
                .accessibilityHidden(true)
                .padding(.bottom, 20)
            Text(title).font(.largeTitle.weight(.bold)).multilineTextAlignment(.center)
            if let message {
                // A width of its own at the least: asked how narrow it could be, a text that may
                // grow downwards answers "one letter wide and very tall", and a window whose
                // content is that tall pushes its own sidebar out of sight.
                Text(message).font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(minWidth: 300, maxWidth: 460).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
            content.padding(.top, 26)
        }
    }
}

/// Where the user is on the way in: signing in, then linking.
private struct StepDots: View {
    let step: Int

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<2, id: \.self) { index in
                Capsule().fill(index == step ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary)).frame(width: index == step ? 18 : 7, height: 7)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \(step + 1) of 2")
    }
}

/// Everything before a phone is connected: sign-in, linking, and failures.
struct OnboardingView: View {
    @ObservedObject var model: AppModel

    private var step: Int? {
        switch model.phase {
        case .signedOut, .signingIn: return 0
        case .linking: return 1
        default: return nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            page
            Spacer(minLength: 0)
            if let step { StepDots(step: step).padding(.top, 12) }
        }
        .padding(.horizontal, 40).padding(.vertical, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The window's frame goes clear over these screens: there is no sidebar to line up with.
        .toolbarBackground(.hidden, for: .windowToolbar)
    }

    @ViewBuilder private var page: some View {
        switch model.phase {
        case .starting:
            // Nothing is known yet; nothing is asked.
            OnboardingPage(symbol: "smartphone", title: "Phone Mac Link", message: "Looking for your phone…") {
                ProgressView().controlSize(.large)
            }
        case .signedOut:
            welcome
        case .signingIn(let code, let url, let expires):
            SignInView(code: code, url: url, expires: expires, embedsPage: model.embedsLivePages) { model.actions?.cancelSignIn() }
        case .linking(let step):
            PairingView(step: step, model: model)
        case .connecting(let name):
            OnboardingPage(symbol: "smartphone", title: "Connecting to \(name)", message: model.connectionDetail) {
                ProgressView().controlSize(.large)
            }
        case .failed(let message, let canRetry):
            OnboardingPage(symbol: "exclamationmark.triangle.fill", tint: .orange, title: "Something Went Wrong", message: message) {
                if canRetry {
                    Button("Try Again") { model.actions?.retry() }
                        .controlSize(.extraLarge).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
        case .connected:
            EmptyView()
        }
    }

    private var welcome: some View {
        VStack(spacing: 0) {
            Text("Your phone, on your Mac").font(.system(size: 30, weight: .bold)).multilineTextAlignment(.center)
            Text("Everything Link to Windows on your Android phone shares, in a Mac app.")
                .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(minWidth: 300, maxWidth: 520).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            WelcomeTiles().padding(.top, 22).frame(maxWidth: 640)
            Button("Sign In with Microsoft") { model.actions?.signIn() }
                .controlSize(.extraLarge).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .padding(.top, 22)
            Text("Use the same Microsoft account as on your phone.").font(.footnote).foregroundStyle(.secondary)
                .padding(.top, 10)
        }
    }
}

/// What the app does, as a grid of tiles in the sections' colours: the big one for the
/// phone itself, the others around it.
private struct WelcomeTiles: View {
    var body: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                tile(.notifications, "Notifications", "Read, answer and act on them.")
                tile(.messages, "Messages", "Your texts, with pictures.")
                tile(.calls, "Calls", "Answer and place calls from here.")
            }
            GridRow {
                hero.gridCellColumns(2)
                tile(.photos, "Photos", "Recent photos, ready to drag out.")
            }
            GridRow {
                tile(.files, "Files", "Send and receive either way.")
                tile(.clipboard, "Clipboard", "Copy there, paste here.")
                tile(.screen, "Phone Screen", "Use the phone from the Mac.")
            }
        }
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.36, green: 0.62, blue: 1.0), Color(red: 0.16, green: 0.36, blue: 0.95)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            // A phone drawn with light, leaning out of the tile.
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.85), lineWidth: 3)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.14)))
                .frame(width: 62, height: 112)
                .rotationEffect(.degrees(-12))
                .offset(x: 230, y: -10)
            VStack(alignment: .leading, spacing: 4) {
                Text("Phone Mac Link").font(.title.weight(.bold))
                Text("Android and Mac, together.").font(.callout).opacity(0.85)
            }
            .foregroundStyle(.white)
            .padding(18)
        }
        .frame(height: 124)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Color(red: 0.16, green: 0.36, blue: 0.95).opacity(0.25), radius: 14, y: 6)
        .accessibilityElement(children: .combine)
    }

    private func tile(_ item: SidebarItem, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            IconTile(symbol: item.tileSymbol, tint: item.tint, size: 34)
            Spacer(minLength: 10)
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 100, maxHeight: .infinity, alignment: .topLeading)
        .background(LinearGradient(colors: [item.tint.opacity(0.14), item.tint.opacity(0.04)], startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(item.tint.opacity(0.16), lineWidth: 0.5) }
        .accessibilityElement(children: .combine)
    }
}

/// Shows the one-time code for the device sign-in page.
struct SignInCodeView: View {
    let code: String
    let url: String
    let expires: Date
    let cancel: () -> Void

    var body: some View {
        OnboardingPage(symbol: "person.badge.key.fill", title: "Sign In to Microsoft",
                       message: "Open the page below on any device and enter this code.") {
            VStack(spacing: 18) {
                CodeBoxes(code, label: "Sign-in code")
                HStack(spacing: 10) {
                    if let link = URL(string: url) {
                        Link(destination: link) { Label(url.replacingOccurrences(of: "https://", with: ""), systemImage: "safari") }
                            .buttonStyle(.bordered).controlSize(.large)
                    }
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                    } label: { Label("Copy Code", systemImage: "doc.on.doc") }
                        .controlSize(.large)
                }
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let remaining = max(0, Int(expires.timeIntervalSince(context.date)))
                        Text(remaining > 0 ? "Waiting for you to sign in · code expires in \(remaining / 60):\(String(format: "%02d", remaining % 60))" : "The code has expired")
                            .font(.footnote).foregroundStyle(remaining > 60 ? Color.secondary : Color.orange).monospacedDigit()
                    }
                }
                Button("Cancel", role: .cancel, action: cancel).buttonStyle(.link)
            }
        }
    }
}

/// One screen per step of linking a phone.
struct PairingView: View {
    let step: PairingStep?
    @ObservedObject var model: AppModel

    var body: some View {
        switch step {
        case nil:
            OnboardingPage(symbol: "qrcode.viewfinder", title: "Link Your Phone",
                           message: "You need the Link to Windows app on the phone, signed in to the same Microsoft account.") {
                VStack(spacing: 12) {
                    Button("Show QR Code") { model.actions?.startPairing(manual: false) }
                        .controlSize(.extraLarge).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    Button("Pair with a code instead") { model.actions?.startPairing(manual: true) }.buttonStyle(.link)
                }
            }
        case .showLink(let link, let expires, let manualLink, let pairingPIN):
            VStack(spacing: 22) {
                Text("Scan with Your Phone").font(.largeTitle.weight(.bold))
                HStack(alignment: .center, spacing: 36) {
                    QRCodeView(text: link).frame(width: 220, height: 220)
                        .shadow(color: .black.opacity(0.12), radius: 14, y: 5)
                    VStack(alignment: .leading, spacing: 16) {
                        numbered(1, "Open **Link to Windows** on the phone, or its camera.")
                        numbered(2, "Point it at this code.")
                        numbered(3, "Follow the steps on the phone. This screen continues by itself.")
                        if let expires { Countdown(prefix: "Code expires in", until: expires).padding(.top, 2) }
                    }
                    .frame(maxWidth: 300, alignment: .leading)
                }
                VStack(spacing: 6) {
                    if let pairingPIN, let manualLink {
                        Text("Or go to **\(manualLink)** on the phone and enter **\(pairingPIN)**").font(.callout).foregroundStyle(.secondary)
                    }
                    Button("Pair with a code instead") { model.actions?.startPairing(manual: true) }.buttonStyle(.link)
                }
            }
        case .confirmChallengePIN(let pin, let expires):
            OnboardingPage(symbol: "checkmark.shield.fill", tint: .green, title: "Confirm on Your Phone",
                           message: "Your phone is asking for the code shown here.") {
                VStack(spacing: 14) {
                    CodeBoxes(pin, label: "Code")
                    if let expires { Countdown(prefix: "Code expires in", until: expires) }
                }
            }
        case .enterPairingPIN(let pin, let expires):
            OnboardingPage(symbol: "number", title: "Enter This Code on Your Phone",
                           message: "In Link to Windows, choose to pair with a code, then type it in.") {
                VStack(spacing: 14) {
                    CodeBoxes(pin, label: "Code")
                    if let expires { Countdown(prefix: "Code expires in", until: expires) }
                }
            }
        case .challengePINProblem(let expired):
            OnboardingPage(symbol: "number", tint: .orange, title: expired ? "The Code Expired" : "The Code Did Not Match",
                           message: "Get a new code and try again on your phone.") {
                Button("Get a New Code") { model.actions?.refreshChallengePIN() }
                    .controlSize(.extraLarge).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        case .approvePermissionsOnPhone:
            OnboardingPage(symbol: "hand.tap.fill", title: "Finish on Your Phone",
                           message: "Allow the permissions Link to Windows asks for. This screen continues by itself.") {
                ProgressView().controlSize(.large)
            }
        case .completing:
            OnboardingPage(symbol: "smartphone", title: "Finishing…") {
                ProgressView().controlSize(.large)
            }
        case .paired:
            OnboardingPage(symbol: "checkmark", tint: .green, title: "Phone Linked") { EmptyView() }
        case .failed(let failure):
            OnboardingPage(symbol: "exclamationmark.triangle.fill", tint: .orange, title: PairingView.title(failure),
                           message: PairingView.explanation(failure)) {
                // Always offer a way forward: after fixing the cause on the phone, the user starts again.
                Button("Start Over") { model.actions?.startPairing(manual: false) }
                    .controlSize(.extraLarge).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func numbered(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)").font(.callout.weight(.semibold)).foregroundStyle(.white)
                .frame(width: 24, height: 24).background(Color.accentColor, in: Circle())
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    static func title(_ failure: PairingFailure) -> String {
        switch failure {
        case .accountMismatch: return "Different Microsoft account"
        case .linkExpired, .pinExpired, .sessionExpired: return "Linking timed out"
        case .requiredPermissionDenied: return "A required permission was denied"
        case .serviceFailure, .unknownState: return "Linking failed"
        }
    }

    static func explanation(_ failure: PairingFailure) -> String {
        switch failure {
        case .accountMismatch: return "The phone is signed in to a different Microsoft account. Sign in with the same account on both, then try again."
        case .linkExpired: return "The QR code was not scanned in time."
        case .pinExpired: return "The code was not entered in time."
        case .sessionExpired: return "Linking took too long."
        case .requiredPermissionDenied: return "Link to Windows needs that permission on the phone to work."
        case .serviceFailure(let type): return type.map { "The service reported: \($0)." } ?? "The service could not complete linking."
        case .unknownState(let state): return "The service reported a state this version does not understand (\(state))."
        }
    }
}

/// A code to read off and type elsewhere: one box per character, as the system shows codes.
struct CodeBoxes: View {
    let code: String
    let label: String
    init(_ code: String, label: String) {
        self.code = code
        self.label = label
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(code.enumerated()), id: \.offset) { _, character in
                Text(String(character))
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .frame(width: 44, height: 56)
                    .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(label) \(code.map(String.init).joined(separator: " "))")
        .accessibilityAddTraits(.isStaticText)
        .contextMenu {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
            }
        }
    }
}

struct PINText: View {
    let pin: String
    init(_ pin: String) { self.pin = pin }

    var body: some View { CodeBoxes(pin, label: "Code") }
}

struct Countdown: View {
    let prefix: String
    let until: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, Int(until.timeIntervalSince(context.date)))
            Label("\(prefix) \(remaining / 60):\(String(format: "%02d", remaining % 60))", systemImage: "clock")
                .font(.footnote).monospacedDigit()
                .foregroundStyle(remaining > 60 ? Color.secondary : Color.orange)
        }
    }
}
