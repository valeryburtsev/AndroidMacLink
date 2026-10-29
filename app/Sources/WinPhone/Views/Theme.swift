import AppKit
import SwiftUI

/// The look shared by every screen: a colour for each section, its symbol on a tile of that
/// colour, content on cards, and a quiet backdrop behind them.
enum Theme {
    /// Corner radius of cards.
    static let cardRadius: CGFloat = 14
    /// The sidebar's floating panel: its corners, and its distance from the window's edges.
    static let panelRadius: CGFloat = 18
    static let panelInset: CGFloat = 8
    /// The backdrop behind cards: a cool, light grey by day, the window's own colour by night.
    static let canvas = Color(nsColor: canvasColor)
    /// The backdrop for AppKit, such as a window's own background.
    static let canvasColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
            : NSColor(srgbRed: 0.957, green: 0.965, blue: 0.980, alpha: 1)
    }
    /// A card on the backdrop: white by day, a lifted grey by night.
    static let card = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.17, green: 0.17, blue: 0.18, alpha: 1)
            : .white
    })
}

extension SidebarItem {
    /// The section's colour, on its tile in the sidebar and wherever it stands for itself.
    var tint: Color {
        switch self {
        case .notifications: return Color(red: 1.00, green: 0.27, blue: 0.27)
        case .messages: return Color(red: 0.20, green: 0.78, blue: 0.35)
        case .calls: return Color(red: 0.19, green: 0.74, blue: 0.42)
        case .contacts: return Color(red: 0.55, green: 0.56, blue: 0.60)
        case .photos: return Color(red: 1.00, green: 0.62, blue: 0.04)
        case .files: return Color(red: 0.16, green: 0.56, blue: 1.00)
        case .storage: return Color(red: 0.35, green: 0.42, blue: 0.95)
        case .screen: return Color(red: 0.36, green: 0.36, blue: 0.90)
        case .apps: return Color(red: 0.69, green: 0.32, blue: 0.87)
        case .links: return Color(red: 0.00, green: 0.66, blue: 0.85)
        case .clipboard: return Color(red: 0.20, green: 0.70, blue: 0.68)
        case .devices: return Color(red: 0.40, green: 0.45, blue: 0.53)
        }
    }

    /// The filled form of the symbol, for white on a tile.
    var tileSymbol: String {
        switch self {
        case .notifications: return "bell.fill"
        case .messages: return "message.fill"
        case .calls: return "phone.fill"
        case .contacts: return "person.crop.circle.fill"
        case .photos: return "photo.fill"
        case .files: return "folder.fill"
        case .storage: return "internaldrive.fill"
        case .screen: return "iphone.gen3"
        case .apps: return "square.grid.2x2.fill"
        case .links: return "link"
        case .clipboard: return "doc.on.clipboard.fill"
        case .devices: return "laptopcomputer.and.iphone"
        }
    }
}

/// A white symbol on a rounded tile of colour, lit from above, as the system's own settings
/// show their sections.
struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(tint)
            .overlay {
                // Light from above: the top a little paler than the colour itself.
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .fill(LinearGradient(colors: [.white.opacity(0.24), .clear], startPoint: .top, endPoint: .bottom))
            }
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .strokeBorder(.white.opacity(0.22), lineWidth: 0.5)
            }
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.12), radius: 0.5, y: 0.5)
            }
            .frame(width: size, height: size)
            .shadow(color: tint.opacity(size > 30 ? 0.3 : 0), radius: size * 0.2, y: size * 0.08)
            .accessibilityHidden(true)
    }
}

extension View {
    /// Sets the sidebar, full or as a strip of symbols, on a panel floating inside the window,
    /// as Telegram does: rounded, lifted off a quiet backdrop, reaching up past the toolbar so
    /// that the window's close, minimise and zoom buttons sit on it.
    func floatingPanel() -> some View {
        self
            .background {
                RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous)
                    .fill(Theme.card)
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(0.07), radius: 8, y: 2)
                    .padding(.top, Theme.panelInset)
                    .ignoresSafeArea(edges: .top)
            }
            .padding(.leading, Theme.panelInset).padding(.bottom, Theme.panelInset)
            .padding(.trailing, Theme.panelInset / 2)
            .background(Theme.canvas.ignoresSafeArea())
    }

    /// The room round a page's cards: to the window's edges and below the toolbar.
    func pageInset() -> some View {
        padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 16)
    }

    /// Sets the content on a card: a rounded, lifted surface with a hairline edge.
    func card(padding: CGFloat = 0) -> some View {
        self.padding(padding)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            }
            // One shadow for the card as a whole, not one under each thing on it.
            .compositingGroup()
            .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
    }
}

/// A screen with nothing to show yet: the section's tile, what is missing, what to do, and
/// the buttons for it.
struct EmptyState<Actions: View>: View {
    let title: String
    let symbol: String
    var tint: Color = .accentColor
    var message: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 12) {
            IconTile(symbol: symbol, tint: tint, size: 64)
                .padding(.bottom, 6)
            Text(title).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
            if let message {
                Text(message).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: 380).fixedSize(horizontal: false, vertical: true)
            }
            actions.padding(.top, 6)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyState where Actions == EmptyView {
    init(title: String, symbol: String, tint: Color = .accentColor, message: String? = nil) {
        self.init(title: title, symbol: symbol, tint: tint, message: message) { EmptyView() }
    }
}
