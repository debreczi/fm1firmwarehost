import SwiftUI

enum Theme {
    static let accent = Color(hex: "#42f5f5")
    static let warm = Color(hex: "#ff6a3d")
    static let background = Color(hex: "#0b0d12")
    static let surface = Color(hex: "#151922")
    static let surfaceRaised = Color(hex: "#1c212c")
    static let stroke = Color.white.opacity(0.07)
    static let textDim = Color.white.opacity(0.62)
    static let textFaint = Color.white.opacity(0.4)
    static let ok = Color(hex: "#5be38a")
    static let err = Color(hex: "#ff5f6d")
    static let warn = Color(hex: "#ffc83d")
    static let radius: CGFloat = 18
}

struct CardStyle: ViewModifier {
    var tint: Color? = nil
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .fill(Theme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                            .strokeBorder(tint.map { $0.opacity(0.22) } ?? Theme.stroke, lineWidth: 1)
                    )
            )
    }
}

extension View {
    func card(tint: Color? = nil) -> some View { modifier(CardStyle(tint: tint)) }

    func hubBackground() -> some View {
        background(Theme.background.ignoresSafeArea())
    }
}

/// A small label with a tinted background: a kind, a licence, a state.
struct Chip: View {
    let text: String
    var icon: String? = nil
    var tint: Color = Theme.textDim
    var filled = false

    var body: some View {
        HStack(spacing: 4) {
            if let icon = icon { Image(systemName: icon).font(.system(size: 10, weight: .semibold)) }
            Text(text)
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .foregroundStyle(filled ? Color.black.opacity(0.85) : tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(filled ? tint : tint.opacity(0.14)))
    }
}

/// A primary action: the big tinted button of a card.
struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.black.opacity(0.88))
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(configuration.isPressed ? 0.7 : 1)))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var tint: Color = .white
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(tint.opacity(configuration.isPressed ? 0.6 : 0.92))
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
    }
}

/// A square key with one symbol, the height of the primary button next to it.
struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.6 : 0.92))
            .frame(width: 44, height: 42)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
    }
}

extension Date {
    var shortText: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: self)
    }
}

extension String {
    /// "2026-10-24" -> "24 Oct 2026"
    var dayText: String {
        let p = DateFormatter(); p.dateFormat = "yyyy-MM-dd"; p.locale = Locale(identifier: "en_US_POSIX")
        guard let d = p.date(from: String(prefix(10))) else { return self }
        let f = DateFormatter(); f.dateStyle = .medium
        return f.string(from: d)
    }
}
