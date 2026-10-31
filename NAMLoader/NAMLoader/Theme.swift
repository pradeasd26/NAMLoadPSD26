import SwiftUI

/// Warna dan komponen visual bersama (gaya "signal chain" gelap kebiruan).
enum Theme {
    static let bgTop = Color(red: 0.07, green: 0.17, blue: 0.24)
    static let bgBottom = Color(red: 0.03, green: 0.08, blue: 0.12)
    static let text = Color(red: 0.80, green: 0.88, blue: 0.92)
    static let dim = Color(red: 0.50, green: 0.62, blue: 0.68)
    static let cyan = Color(red: 0.25, green: 0.85, blue: 0.95)
    static let green = Color(red: 0.45, green: 0.90, blue: 0.65)
    static let amber = Color(red: 1.00, green: 0.80, blue: 0.38)
    static let orange = Color(red: 1.00, green: 0.60, blue: 0.32)
    static let red = Color(red: 1.00, green: 0.38, blue: 0.38)
}

struct AppBackground: View {
    var body: some View {
        LinearGradient(colors: [Theme.bgTop, Theme.bgBottom], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }
}

struct GlassCard: ViewModifier {
    var tint: Color
    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(tint.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(tint.opacity(0.30), lineWidth: 1))
    }
}

extension View {
    func glassCard(_ tint: Color = Theme.cyan) -> some View {
        modifier(GlassCard(tint: tint))
    }
}

struct Caption: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.6)
            .textCase(.uppercase)
            .foregroundStyle(Theme.dim)
    }
}

struct PillButton: ButtonStyle {
    var color: Color
    var filled: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(filled ? Color.black.opacity(0.85) : color)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Capsule().fill(filled ? color : color.opacity(0.14)))
            .overlay(Capsule().stroke(color.opacity(0.5), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
