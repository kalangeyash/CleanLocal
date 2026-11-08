import SwiftUI

/// Large in-content page title with optional trailing controls.
struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    init(title: String, subtitle: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.l) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                    .font(.pageTitle)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }
            Spacer(minLength: Spacing.l)
            trailing()
        }
    }
}

/// Friendly empty / zero state.
struct EmptyStateView<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    var tint: Color = Palette.brandIndigo
    @ViewBuilder var actions: () -> Actions

    init(symbol: String, title: String, message: String, tint: Color = Palette.brandIndigo,
         @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.tint = tint
        self.actions = actions
    }

    var body: some View {
        VStack(spacing: Spacing.l) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.12))
                    .frame(width: 96, height: 96)
                Circle()
                    .strokeBorder(tint.opacity(0.18), lineWidth: 1)
                    .frame(width: 124, height: 124)
                Image(systemName: symbol)
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(tint.gradient)
                    .symbolRenderingMode(.hierarchical)
            }
            .accessibilityHidden(true)
            VStack(spacing: Spacing.xs) {
                Text(title).font(.title2.weight(.semibold))
                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            actions()
        }
        .padding(Spacing.xxxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A dashboard metric tile.
struct StatTile: View {
    let title: String
    let value: String
    var caption: String?
    let symbol: String
    var tint: Color = Palette.brandIndigo
    var action: (() -> Void)?

    var body: some View {
        let content = VStack(alignment: .leading, spacing: Spacing.m) {
            HStack {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.gradient))
                Spacer()
                if action != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.statValue)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                // Always reserve the caption line so tiles in a row share one height.
                Text(caption ?? " ")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .accessibilityHidden(caption == nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")

        if let action {
            Button(action: action) { content }
                .buttonStyle(.plain)
                .hoverLift()
        } else {
            content
        }
    }
}

/// Inline informational / warning banner.
struct InfoBanner: View {
    enum Style {
        case info, warning, privacy, success

        var symbol: String {
            switch self {
            case .info: "info.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .privacy: "lock.shield.fill"
            case .success: "checkmark.seal.fill"
            }
        }

        var tint: Color {
            switch self {
            case .info: Palette.brandIndigo
            case .warning: Palette.warning
            case .privacy: Palette.brandTeal
            case .success: Palette.success
            }
        }
    }

    let style: Style
    var title: String?
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            Image(systemName: style.symbol)
                .font(.system(size: 16))
                .foregroundStyle(style.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if let title { Text(title).font(.callout.weight(.semibold)) }
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.m)
        .background(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous).fill(style.tint.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous).strokeBorder(style.tint.opacity(0.18)))
        .accessibilityElement(children: .combine)
    }
}

/// Pill-shaped segmented filter.
struct ChipPicker<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String

    var body: some View {
        HStack(spacing: Spacing.xs) {
            ForEach(options, id: \.self) { option in
                Chip(title: title(option), isSelected: option == selection) {
                    withAnimation(.cleanLocalSpring) { selection = option }
                }
            }
        }
    }
}

struct Chip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background {
                    Capsule().fill(isSelected ? AnyShapeStyle(Palette.brandGradient) : AnyShapeStyle(isHovering ? Palette.strongFill : Palette.subtleFill))
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.cleanLocalHover, value: isHovering)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

/// Small rounded label (e.g. "Keep", "Photos").
struct Badge: View {
    let text: String
    var symbol: String?
    var tint: Color = Palette.brandIndigo

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .font(.caption2.weight(.bold))
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.14)))
    }
}

/// Determinate or indeterminate analysis progress, with an optional cancel button.
struct AnalysisProgressView: View {
    let message: String
    let fraction: Double?
    var onCancel: (() -> Void)?

    var body: some View {
        HStack(spacing: Spacing.m) {
            if let fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 240)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if let onCancel {
                Button("Stop", action: onCancel).buttonStyle(.glass)
            }
        }
        .card(padding: Spacing.m)
    }
}
