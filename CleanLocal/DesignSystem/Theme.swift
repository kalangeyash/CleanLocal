import AppKit
import SwiftUI

/// Spacing scale (4-pt based).
enum Spacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 6
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 28
    static let xxxl: CGFloat = 40
}

enum Radius {
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let large: CGFloat = 16
    static let xlarge: CGFloat = 22
}

/// CleanLocal's color system.
///
/// The seven brand colors below are the single source of truth; every other color in the
/// app is derived from them. Contrast rule: text and glyphs drawn on any brand fill use
/// ``onBrand`` (black), which keeps every combination at WCAG AA or better
/// (white on these oranges would be only 2.5–3.5 : 1).
enum Palette {
    // MARK: Brand palette

    static let black = Color(hex: 0x000000)
    static let grey = Color(hex: 0x80807E)
    static let porcelain = Color(hex: 0xFFFFFC)
    static let khaki = Color(hex: 0xBEB7A4)
    static let tangerine = Color(hex: 0xFF7F11)
    static let blaze = Color(hex: 0xFF5F09)
    static let flame = Color(hex: 0xFF3F00)

    // MARK: Semantic roles

    /// Selection, focus rings and interactive highlights (mirrors the AccentColor asset).
    static let accent = blaze
    /// Text and glyphs placed on any brand-colored fill.
    static let onBrand = black
    /// High-emphasis foreground: Black in light mode, Porcelain in dark mode.
    static let ink = adaptive(light: .black, dark: nsColor(0xFFFFFC))
    /// The opposite of ``ink``, for text on ``ink`` fills.
    static let inkInverse = adaptive(light: nsColor(0xFFFFFC), dark: .black)

    static let destructive = flame
    static let warning = tangerine
    /// "Keep" / completed states. Always paired with ``onBrand`` content.
    static let success = khaki
    static let neutral = grey

    static let brandGradient = LinearGradient(
        colors: [tangerine, blaze, flame],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
    static let heroGradient = LinearGradient(
        colors: [tangerine, blaze, flame],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
    /// For large display text only (Blaze → Flame keeps ≥ 3 : 1 on Porcelain).
    static let accentTextGradient = LinearGradient(colors: [blaze, flame], startPoint: .leading, endPoint: .trailing)

    // MARK: Surfaces

    /// Porcelain warmed with 16 % Khaki in light mode; pure Black in dark mode.
    static let pageBackground = adaptive(light: nsColor(0xF5F4EE), dark: .black)
    /// Porcelain in light mode; Black lifted with 17 % Grey in dark mode.
    static let cardBackground = adaptive(light: nsColor(0xFFFFFC), dark: nsColor(0x161615))
    static let cardStroke = adaptive(light: nsColor(0xBEB7A4, alpha: 0.45), dark: nsColor(0x80807E, alpha: 0.28))
    static let subtleFill = adaptive(light: nsColor(0xBEB7A4, alpha: 0.18), dark: nsColor(0x80807E, alpha: 0.18))
    static let strongFill = adaptive(light: nsColor(0xBEB7A4, alpha: 0.34), dark: nsColor(0x80807E, alpha: 0.30))
    /// Backdrop behind previewed media.
    static let canvas = adaptive(light: nsColor(0xECE9E0), dark: .black)

    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    static func nsColor(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(nsColor: Palette.nsColor(hex))
    }
}

extension MediaCategory {
    var tint: Color {
        switch self {
        case .photos: Palette.tangerine
        case .videos: Palette.flame
        case .screenshots: Palette.khaki
        case .other: Palette.grey
        }
    }

    var gradient: LinearGradient {
        LinearGradient(colors: [tint, tint.opacity(0.78)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension Font {
    static let heroTitle = Font.system(size: 30, weight: .bold, design: .rounded)
    static let pageTitle = Font.system(size: 26, weight: .bold, design: .rounded)
    static let statValue = Font.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit()
    static let cardTitle = Font.system(.headline, design: .rounded)
}

/// Standard animation curves.
extension Animation {
    static let cleanLocalSpring = Animation.spring(response: 0.35, dampingFraction: 0.82)
    static let cleanLocalHover = Animation.easeOut(duration: 0.15)
}
