import SwiftUI

// MARK: - Card

struct CardModifier: ViewModifier {
    var padding: CGFloat = Spacing.l
    var cornerRadius: CGFloat = Radius.large

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Palette.cardBackground)
                    .shadow(color: Palette.black.opacity(0.05), radius: 10, y: 3)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Palette.cardStroke)
            }
    }
}

extension View {
    func card(padding: CGFloat = Spacing.l, cornerRadius: CGFloat = Radius.large) -> some View {
        modifier(CardModifier(padding: padding, cornerRadius: cornerRadius))
    }

    /// Slight lift on hover for interactive surfaces.
    func hoverLift(scale: CGFloat = 1.012) -> some View {
        modifier(HoverLiftModifier(scale: scale))
    }
}

struct HoverLiftModifier: ViewModifier {
    let scale: CGFloat
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isHovering ? scale : 1)
            .shadow(color: .black.opacity(isHovering ? 0.08 : 0), radius: 12, y: 5)
            .animation(.cleanLocalHover, value: isHovering)
            .onHover { isHovering = $0 }
    }
}

// MARK: - Buttons

/// The main call-to-action: an ink pill (Black on light, Porcelain on dark).
///
/// Kept neutral on purpose so it never looks like the orange destructive button.
struct PrimaryButtonStyle: ButtonStyle {
    var size: ControlSize = .regular

    func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonBody(configuration: configuration, size: size)
    }

    private struct PrimaryButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let size: ControlSize
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(.system(size == .large ? .title3 : .body, design: .rounded, weight: .semibold))
                .foregroundStyle(Palette.inkInverse)
                .padding(.horizontal, size == .large ? 26 : 16)
                .padding(.vertical, size == .large ? 13 : 8)
                .background { Capsule().fill(Palette.ink) }
                .overlay(alignment: .bottom) {
                    // Brand underline that grows on hover.
                    Capsule()
                        .fill(Palette.brandGradient)
                        .frame(height: 3)
                        .padding(.horizontal, isHovering ? 14 : 28)
                        .opacity(isHovering && isEnabled ? 1 : 0)
                        .offset(y: -3)
                }
                .shadow(color: .black.opacity(isEnabled ? 0.18 : 0), radius: configuration.isPressed ? 2 : 8, y: 3)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .animation(.cleanLocalHover, value: configuration.isPressed)
                .animation(.cleanLocalHover, value: isHovering)
                .onHover { isHovering = $0 }
                .contentShape(Capsule())
        }
    }
}

/// A quiet secondary button for cards and for the orange hero.
struct GlassButtonStyle: ButtonStyle {
    var onGradient = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .rounded, weight: .medium))
            .foregroundStyle(onGradient ? Palette.onBrand : Palette.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(onGradient
                    ? AnyShapeStyle(Palette.black.opacity(configuration.isPressed ? 0.2 : 0.12))
                    : AnyShapeStyle(configuration.isPressed ? Palette.strongFill : Palette.subtleFill))
            )
            .overlay(Capsule().strokeBorder(onGradient ? Palette.black.opacity(0.18) : Palette.cardStroke))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.cleanLocalHover, value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// Destructive confirmation: Blazing Flame with black text (≈ 6 : 1 contrast).
struct DestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DestructiveBody(configuration: configuration)
    }

    private struct DestructiveBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(.body, design: .rounded, weight: .semibold))
                .foregroundStyle(Palette.onBrand)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Capsule().fill(Palette.destructive))
                .overlay(Capsule().strokeBorder(Palette.black.opacity(0.12)))
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(isEnabled ? 1 : 0.45)
                .animation(.cleanLocalHover, value: configuration.isPressed)
                .contentShape(Capsule())
        }
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
    static var primaryLarge: PrimaryButtonStyle { PrimaryButtonStyle(size: .large) }
}

extension ButtonStyle where Self == GlassButtonStyle {
    static var glass: GlassButtonStyle { GlassButtonStyle() }
    static var glassOnGradient: GlassButtonStyle { GlassButtonStyle(onGradient: true) }
}

extension ButtonStyle where Self == DestructiveButtonStyle {
    static var destructive: DestructiveButtonStyle { DestructiveButtonStyle() }
}
