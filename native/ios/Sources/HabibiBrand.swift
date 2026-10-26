import SwiftUI
import UIKit

struct HabibiPalette: Equatable {
    let tokens: [String: String]
    var accent: Color { color("primary") }
    var canvas: Color { color("background") }
    var ink: Color { color("text") }
    var muted: Color { color("textMuted") }
    var glow: Color { color("accent") }
    var surface: Color { color("surface") }
    var onPrimary: Color { color("onPrimary") }
    var border: Color { color("border") }

    private func color(_ key: String) -> Color { Color(habibiHex: tokens[key]!) }
}

extension Color {
    init(habibiHex value: String) {
        let number = UInt32(value.dropFirst(), radix: 16)!
        self.init(.sRGB, red: Double(number >> 16 & 255) / 255, green: Double(number >> 8 & 255) / 255,
                  blue: Double(number & 255) / 255, opacity: 1)
    }
}

private struct HabibiPaletteKey: EnvironmentKey {
    static let defaultValue = HabibiPalette(tokens: HabibiThemeCatalog.bundled.theme(nil).colors.light)
}

extension EnvironmentValues {
    var habibiPalette: HabibiPalette {
        get { self[HabibiPaletteKey.self] }
        set { self[HabibiPaletteKey.self] = newValue }
    }
}

struct HabibiMark: View {
    var size: CGFloat = 64
    @Environment(\.habibiPalette) private var palette
    var body: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: size * 0.48, weight: .medium))
            .foregroundStyle(palette.onPrimary)
            .frame(width: size, height: size)
            .background(palette.accent, in: RoundedRectangle(cornerRadius: size * 0.22))
            .accessibilityHidden(true)
    }
}

struct HabibiAtmosphere: View {
    @Environment(\.habibiPalette) private var palette
    var body: some View {
        palette.canvas.overlay {
            GeometryReader { geometry in
                RadialGradient(colors: [palette.glow.opacity(0.65), .clear], center: .topTrailing,
                               startRadius: 0, endRadius: max(520, geometry.size.width))
                RadialGradient(colors: [palette.glow.opacity(0.3), .clear], center: .bottomLeading,
                               startRadius: 0, endRadius: 400)
            }
        }.ignoresSafeArea()
    }
}
