import SwiftUI

/// One tile in the media grid.
struct MediaGridCell: View {
    let item: MediaItem
    let isSelected: Bool
    let isFocused: Bool
    let onToggleSelection: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            thumbnail
            VStack(alignment: .leading, spacing: 2) {
                Text(item.filename)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(item.displaySize) · \(item.effectiveDate.shortDisplay)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 2)
        }
        .padding(Spacing.xs)
        .background {
            RoundedRectangle(cornerRadius: Radius.medium + 2, style: .continuous)
                .fill(isSelected ? Palette.accent.opacity(0.12) : (isHovering ? Palette.subtleFill : .clear))
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(.cleanLocalHover, value: isHovering)
        .animation(.cleanLocalHover, value: isSelected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction(named: isSelected ? "Deselect" : "Select", onToggleSelection)
    }

    private var thumbnail: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { ThumbnailView(item: item) }
            .clipShape(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
            .overlay(alignment: .topLeading) { selectionToggle }
            .overlay(alignment: .topTrailing) {
                if item.isPhotosAsset {
                    Image(systemName: "photo.stack.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Palette.porcelain)
                        .padding(5)
                        .background(Circle().fill(Palette.black.opacity(0.5)))
                        .padding(Spacing.s)
                        .help("In your Photos library")
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let duration = item.duration, item.kind == .video {
                    Label(duration.formattedDuration, systemImage: "play.fill")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Palette.porcelain)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Palette.black.opacity(0.6)))
                        .padding(Spacing.s)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                    .strokeBorder(
                        isSelected ? Palette.accent : (isFocused ? Palette.accent.opacity(0.55) : Palette.cardStroke),
                        lineWidth: isSelected ? 3 : (isFocused ? 2 : 1)
                    )
            }
            .scaleEffect(isHovering && !isSelected ? 1.015 : 1)
    }

    private var selectionToggle: some View {
        Button(action: onToggleSelection) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(Palette.porcelain, isSelected ? Palette.accent : Palette.black.opacity(0.25))
                .shadow(color: .black.opacity(0.35), radius: 2)
                .padding(Spacing.s)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isSelected || isHovering ? 1 : 0)
        .help(isSelected ? "Deselect" : "Select")
        .accessibilityHidden(true)
    }

    private var accessibilityDescription: String {
        var parts = [item.kind.title, item.filename, item.displaySize, item.effectiveDate.shortDisplay]
        if let duration = item.duration { parts.append(duration.formattedDuration) }
        if item.isPhotosAsset { parts.append("Photos library") }
        return parts.joined(separator: ", ")
    }
}
