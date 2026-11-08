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

/// Brand and semantic colors. Every color adapts to light and dark appearance.
enum Palette {
    static let brandIndigo = Color(red: 0.35, green: 0.40, blue: 0.98)
    static let brandViolet = Color(red: 0.60, green: 0.36, blue: 0.97)
    static let brandTeal = Color(red: 0.18, green: 0.74, blue: 0.86)

    static let brandGradient = LinearGradient(
        colors: [brandIndigo, brandViolet, brandTeal],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    static let heroGradient = LinearGradient(
        colors: [brandIndigo.opacity(0.95), brandViolet.opacity(0.9), Color(red: 0.86, green: 0.38, blue: 0.78).opacity(0.85)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    static let destructive = Color(red: 0.95, green: 0.27, blue: 0.30)
    static let warning = Color(red: 0.98, green: 0.62, blue: 0.13)
    static let success = Color(red: 0.20, green: 0.75, blue: 0.45)

    static let pageBackground = adaptive(light: NSColor(white: 0.965, alpha: 1), dark: NSColor(white: 0.11, alpha: 1))
    static let cardBackground = adaptive(light: .white, dark: NSColor(white: 0.165, alpha: 1))
    static let cardStroke = adaptive(light: NSColor(white: 0, alpha: 0.07), dark: NSColor(white: 1, alpha: 0.08))
    static let subtleFill = adaptive(light: NSColor(white: 0, alpha: 0.045), dark: NSColor(white: 1, alpha: 0.07))
    static let strongFill = adaptive(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.12))

    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

extension MediaCategory {
    var tint: Color {
        switch self {
        case .photos: Color(red: 0.24, green: 0.52, blue: 0.98)
        case .videos: Color(red: 0.64, green: 0.38, blue: 0.96)
        case .screenshots: Color(red: 0.10, green: 0.71, blue: 0.69)
        case .other: Color(red: 0.98, green: 0.58, blue: 0.20)
        }
    }

    var gradient: LinearGradient {
        LinearGradient(colors: [tint, tint.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
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
