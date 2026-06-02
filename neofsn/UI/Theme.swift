import SwiftUI

/// Cartographic-instrument design tokens.
/// Restrained palette, warm-white text, single amber accent that picks up FSN's iconic ground color.
enum Theme {

    // MARK: - Color

    /// Window backdrop. Slightly cool near-black, not pure.
    static let backdrop = Color(red: 0.035, green: 0.038, blue: 0.052)

    /// Floating panel base.
    static let panel = Color(red: 0.072, green: 0.078, blue: 0.098)

    /// Raised panel (e.g. selected row).
    static let panelRaised = Color(red: 0.108, green: 0.118, blue: 0.148)

    /// 1px rule color.
    static let hairline = Color(red: 0.18, green: 0.19, blue: 0.22)

    /// Strong hairline (heavier dividers).
    static let hairlineStrong = Color(red: 0.30, green: 0.32, blue: 0.36)

    /// Body text — warm bone-white. Reads as printed, not screen.
    static let textPrimary = Color(red: 0.918, green: 0.905, blue: 0.880)

    /// Secondary text.
    static let textSecondary = Color(red: 0.535, green: 0.555, blue: 0.595)

    /// Tertiary / muted text (timestamps, breadcrumbs).
    static let textTertiary = Color(red: 0.350, green: 0.370, blue: 0.410)

    /// Amber topaz accent. Echoes the SGI gold of FSN's subdir pedestals.
    static let accent = Color(red: 0.852, green: 0.612, blue: 0.232)

    /// Dim accent (inactive, ancestors).
    static let accentDim = Color(red: 0.548, green: 0.398, blue: 0.155)

    /// Faint accent wash (selection backgrounds).
    static let accentWash = Color(red: 0.852, green: 0.612, blue: 0.232, opacity: 0.13)

    // MARK: - Type

    /// Display serif. Apple's New York at large sizes feels editorial.
    static func display(_ size: CGFloat, weight: Font.Weight = .light) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    /// Italic display, for hero/specimen labels.
    static func displayItalic(_ size: CGFloat, weight: Font.Weight = .light) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    /// Body in SF Pro at a chosen size.
    static func body(_ size: CGFloat = 13, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    /// SF Mono — paths, sizes, timestamps. Tabular feel.
    static func mono(_ size: CGFloat = 12, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Compressed-width SF Pro for caps small labels. Tracking applied at use site.
    static func caps(_ size: CGFloat = 10) -> Font {
        .system(size: size, weight: .medium, design: .default).width(.compressed)
    }

    // MARK: - Geometry

    static let panelCorner: CGFloat = 5
    static let panelBorder: CGFloat = 0.5
    static let panelPadding: CGFloat = 14
}

// MARK: - View helpers

extension View {
    /// Floating instrument panel: dark fill, hairline border, sharp-ish corners.
    func instrumentPanel(corner: CGFloat = Theme.panelCorner) -> some View {
        background(
            ZStack {
                Theme.panel.opacity(0.94)
                LinearGradient(
                    colors: [Color.white.opacity(0.04), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .stroke(Theme.hairline, lineWidth: Theme.panelBorder)
        )
        .shadow(color: .black.opacity(0.45), radius: 16, y: 6)
    }

    /// Style for tiny all-caps tracked labels ("SIZE", "MODIFIED", etc.).
    func capsLabel(color: Color = Theme.textTertiary) -> some View {
        self
            .font(Theme.caps(9))
            .tracking(2.2)
            .textCase(.uppercase)
            .foregroundStyle(color)
    }
}
