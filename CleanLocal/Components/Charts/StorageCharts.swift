import Charts
import SwiftUI

/// Interactive donut of media storage by category. Hover or click a slice to focus it.
struct StorageDonutChart: View {
    let breakdown: MediaBreakdown
    @Binding var highlighted: MediaCategory?
    @State private var selectedAngle: Double?

    private var entries: [MediaBreakdown.Entry] { breakdown.entries.filter { $0.bytes > 0 } }

    var body: some View {
        Chart(entries) { entry in
            SectorMark(
                angle: .value("Size", Double(entry.bytes)),
                innerRadius: .ratio(0.66),
                angularInset: 1.5
            )
            .cornerRadius(5)
            .foregroundStyle(entry.category.tint.gradient)
            .opacity(highlighted == nil || highlighted == entry.category ? 1 : 0.3)
            .accessibilityLabel(entry.category.title)
            .accessibilityValue("\(entry.bytes.formattedBytes), \(entry.count) items")
        }
        .chartLegend(.hidden)
        .chartAngleSelection(value: $selectedAngle)
        .onChange(of: selectedAngle) { _, angle in
            withAnimation(.cleanLocalHover) { highlighted = angle.flatMap(category(atCumulative:)) }
        }
        .chartBackground { proxy in
            GeometryReader { geometry in
                if let anchor = proxy.plotFrame {
                    let frame = geometry[anchor]
                    centerLabel
                        .position(x: frame.midX, y: frame.midY)
                }
            }
        }
        .animation(.cleanLocalSpring, value: breakdown)
    }

    private var centerLabel: some View {
        let entry = highlighted.map(breakdown.entry(for:))
        return VStack(spacing: 2) {
            Text(entry?.bytes.formattedBytes ?? breakdown.totalBytes.formattedBytes)
                .font(.system(.title2, design: .rounded, weight: .bold))
                .contentTransition(.numericText())
            Text(entry?.category.title ?? "Total media")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityHidden(true)
    }

    private func category(atCumulative value: Double) -> MediaCategory? {
        var running = 0.0
        for entry in entries {
            running += Double(entry.bytes)
            if value <= running { return entry.category }
        }
        return nil
    }
}

/// Legend rows for the storage categories. Clicking a row runs `onSelect`.
struct CategoryLegend: View {
    let breakdown: MediaBreakdown
    @Binding var highlighted: MediaCategory?
    var onSelect: ((MediaCategory) -> Void)?

    var body: some View {
        VStack(spacing: Spacing.xs) {
            ForEach(breakdown.entries) { entry in
                Button {
                    onSelect?(entry.category)
                } label: {
                    HStack(spacing: Spacing.s) {
                        RoundedRectangle(cornerRadius: 3).fill(entry.category.tint.gradient).frame(width: 10, height: 10)
                        Text(entry.category.title)
                        Spacer()
                        Text("\(entry.count.formatted())")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text(entry.bytes.formattedBytes)
                            .monospacedDigit()
                            .frame(minWidth: 70, alignment: .trailing)
                    }
                    .font(.callout)
                    .padding(.vertical, 5)
                    .padding(.horizontal, Spacing.s)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(highlighted == entry.category ? entry.category.tint.opacity(0.12) : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { inside in withAnimation(.cleanLocalHover) { highlighted = inside ? entry.category : nil } }
            }
        }
    }
}

/// Horizontal bar showing a volume's used space, with the scanned-media share highlighted.
struct CapacityBar: View {
    let volume: VolumeCapacity
    let mediaBytes: Int64
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? Spacing.xs : Spacing.s) {
            if !compact {
                HStack {
                    Image(systemName: volume.isRemovable ? "externaldrive.fill" : "internaldrive.fill")
                        .foregroundStyle(.secondary)
                    Text(volume.name).font(.headline)
                    Spacer()
                    Text("\(volume.availableBytes.formattedBytes) available of \(volume.totalBytes.formattedBytes)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            GeometryReader { geometry in
                let width = geometry.size.width
                let total = max(Double(volume.totalBytes), 1)
                let media = min(Double(mediaBytes), Double(volume.usedBytes))
                let other = max(Double(volume.usedBytes) - media, 0)
                HStack(spacing: 0) {
                    Rectangle().fill(Palette.brandGradient).frame(width: width * media / total)
                    Rectangle().fill(Palette.grey).frame(width: width * other / total)
                    Spacer(minLength: 0)
                }
                .background(Palette.strongFill)
                .clipShape(Capsule())
            }
            .frame(height: compact ? 6 : 12)
            if !compact {
                HStack(spacing: Spacing.l) {
                    legendDot(Palette.brandGradient, "Scanned media", mediaBytes)
                    legendDot(Palette.grey, "Other data", max(volume.usedBytes - mediaBytes, 0))
                    legendDot(Palette.strongFill, "Available", volume.availableBytes)
                }
                .font(.caption)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(volume.name): \(volume.availableBytes.formattedBytes) available of \(volume.totalBytes.formattedBytes), scanned media uses \(mediaBytes.formattedBytes)")
    }

    private func legendDot<S: ShapeStyle>(_ style: S, _ title: String, _ bytes: Int64) -> some View {
        HStack(spacing: 5) {
            Circle().fill(style).frame(width: 8, height: 8)
            Text(title).foregroundStyle(.secondary)
            Text(bytes.formattedBytes).monospacedDigit()
        }
    }
}
