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
                    .shadow(color: .black.opacity(0.05), radius: 10, y: 3)
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

/// The brand-gradient call-to-action button ("Scan My Mac").
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
                .foregroundStyle(.white)
                .padding(.horizontal, size == .large ? 26 : 16)
                .padding(.vertical, size == .large ? 13 : 8)
                .background {
                    Capsule().fill(Palette.brandGradient)
                        .brightness(isHovering ? 0.06 : 0)
                }
                .overlay { Capsule().strokeBorder(.white.opacity(0.22)) }
                .shadow(color: Palette.brandViolet.opacity(isEnabled ? 0.35 : 0), radius: configuration.isPressed ? 3 : 10, y: 4)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(isEnabled ? 1 : 0.45)
                .animation(.cleanLocalHover, value: configuration.isPressed)
                .animation(.cleanLocalHover, value: isHovering)
                .onHover { isHovering = $0 }
                .contentShape(Capsule())
        }
    }
}

/// A translucent secondary button that sits well on gradients and cards.
struct GlassButtonStyle: ButtonStyle {
    var onGradient = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .rounded, weight: .medium))
            .foregroundStyle(onGradient ? Color.white : Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(onGradient ? Color.white.opacity(configuration.isPressed ? 0.3 : 0.2) : Palette.subtleFill)
            )
            .overlay(Capsule().strokeBorder(onGradient ? Color.white.opacity(0.25) : Palette.cardStroke))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.cleanLocalHover, value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// Destructive confirmation button.
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
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Capsule().fill(Palette.destructive.gradient))
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
