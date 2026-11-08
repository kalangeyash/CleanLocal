import SwiftUI

struct SimilarPhotosView: View {
    @Environment(AnalysisStore.self) private var analysis
    @Environment(SettingsStore.self) private var settings
    @Environment(LibraryStore.self) private var library
    @Environment(DeletionStore.self) private var deletion
    @Environment(\.openWindow) private var openWindow
    @State private var selection = Set<MediaItem.ID>()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            content
        }
        .background(Palette.pageBackground)
        .overlay(alignment: .bottom) {
            if !selectedItems.isEmpty {
                SelectionActionBar(
                    count: selectedItems.count,
                    bytes: StorageAnalyticsService.totalSize(of: selectedItems),
                    canReveal: selectedItems.contains { !$0.isPhotosAsset },
                    onPreview: { selectedItems.first.map { openWindow(id: MediaPreviewScene.id, value: $0.id) } },
                    onReveal: { FinderActions.reveal(selectedItems) },
                    onDeselect: { selection.removeAll() },
                    onMoveToTrash: { deletion.requestDeletion(of: selectedItems) }
                )
                .padding(.bottom, Spacing.xl)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.cleanLocalSpring, value: selection.isEmpty)
        .onChange(of: analysis.similarGroups.map(\.id)) {
            selection.formIntersection(Set(analysis.similarGroups.flatMap { $0.items.map(\.id) }))
        }
    }

    private var header: some View {
        @Bindable var settings = settings
        return VStack(alignment: .leading, spacing: Spacing.m) {
            PageHeader(title: "Similar Photos", subtitle: subtitle) {
                Button(analysis.similarPhase == .notStarted ? "Find Similar Photos" : "Analyze Again") {
                    analysis.analyzeSimilar()
                }
                .buttonStyle(.primary)
                .disabled(analysis.similarPhase.isRunning || library.items.isEmpty)
            }
            HStack(spacing: Spacing.m) {
                Text("Similarity")
                    .font(.callout.weight(.medium))
                Slider(value: $settings.similarityThreshold, in: 0.80...0.98, step: 0.01) {
                    Text("Similarity threshold")
                } minimumValueLabel: {
                    Text("Looser").font(.caption)
                } maximumValueLabel: {
                    Text("Stricter").font(.caption)
                }
                .frame(maxWidth: 320)
                Text("\(Int((settings.similarityThreshold * 100).rounded()))%")
                    .font(.callout.monospacedDigit())
                    .frame(width: 44)
                Spacer()
            }
            if case let .running(progress, message) = analysis.similarPhase {
                AnalysisProgressView(message: message, fraction: progress) { analysis.cancelSimilarAnalysis() }
            }
            InfoBanner(
                style: .info,
                message: "Similar photos aren’t identical — they may be bursts, edits or resized copies. Nothing here is selected for you; review each group and choose what to keep."
            )
        }
        .padding(.horizontal, Spacing.xxl)
        .padding(.top, Spacing.xl)
        .padding(.bottom, Spacing.m)
    }

    private var subtitle: String {
        switch analysis.similarPhase {
        case .notStarted: "Compares photos with on-device perceptual fingerprints"
        case .running: "Analyzing…"
        case let .failed(message): "Analysis failed: \(message)"
        case .completed: "\(analysis.similarGroups.count) groups · \(analysis.similarGroups.reduce(0) { $0 + $1.items.count }) photos"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch analysis.similarPhase {
        case .notStarted where analysis.similarGroups.isEmpty:
            EmptyStateView(
                symbol: "rectangle.stack",
                title: "Find Look-Alike Photos",
                message: "CleanLocal fingerprints each photo’s structure (pHash + dHash) to find near-duplicates such as bursts and resized copies. Your photos never leave this Mac."
            ) {
                Button("Find Similar Photos") { analysis.analyzeSimilar() }
                    .buttonStyle(.primaryLarge)
                    .disabled(library.items.isEmpty)
            }
        case .completed where analysis.similarGroups.isEmpty:
            EmptyStateView(symbol: "checkmark.seal.fill", title: "No Similar Photos",
                           message: "Try a looser similarity setting to widen the search.", tint: Palette.success)
        default:
            ScrollView {
                LazyVStack(spacing: Spacing.l) {
                    ForEach(analysis.similarGroups) { group in
                        SimilarGroupCard(group: group, selection: $selection)
                    }
                }
                .padding(Spacing.xxl)
                .padding(.bottom, 72)
            }
        }
    }

    private var selectedItems: [MediaItem] {
        var seen = Set<MediaItem.ID>()
        return analysis.similarGroups.flatMap(\.items).filter { selection.contains($0.id) && seen.insert($0.id).inserted }
    }
}

private struct SimilarGroupCard: View {
    let group: DuplicateGroup
    @Binding var selection: Set<MediaItem.ID>
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(group.items.count) similar photos").font(.cardTitle)
                    Text("\(Int((group.similarity * 100).rounded()))% alike · \(group.totalBytes.formattedBytes) total")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Select All but Best") {
                    selection.remove(group.suggestedKeeperID)
                    selection.formUnion(group.items.map(\.id).filter { $0 != group.suggestedKeeperID })
                }
                .buttonStyle(.glass)
                .help("Select every photo except the highest-quality one")
            }
            ScrollView(.horizontal) {
                LazyHStack(spacing: Spacing.m) {
                    ForEach(group.items) { item in
                        tile(for: item)
                    }
                }
                .padding(.vertical, Spacing.xxs)
            }
            .scrollIndicators(.automatic)
        }
        .card(padding: Spacing.l)
    }

    private func tile(for item: MediaItem) -> some View {
        let isSelected = selection.contains(item.id)
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            ThumbnailView(item: item)
                .frame(width: 168, height: 168)
                .clipShape(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Palette.cardStroke, lineWidth: isSelected ? 3 : 1))
                .overlay(alignment: .topLeading) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, isSelected ? Color.accentColor : Color.black.opacity(0.25))
                        .shadow(radius: 2)
                        .padding(Spacing.s)
                }
                .overlay(alignment: .bottomLeading) {
                    if item.id == group.suggestedKeeperID {
                        Badge(text: "Best Quality", symbol: "star.fill", tint: .white)
                            .background(Capsule().fill(Palette.success))
                            .padding(Spacing.s)
                    }
                }
                .onTapGesture(count: 2) { openWindow(id: MediaPreviewScene.id, value: item.id) }
                .onTapGesture {
                    if isSelected { selection.remove(item.id) } else { selection.insert(item.id) }
                }
            Text(item.filename).font(.caption.weight(.medium)).lineLimit(1).truncationMode(.middle)
            Text("\(item.dimensionsDescription ?? "—") · \(item.size.formattedBytes)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: 168)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.filename), \(item.size.formattedBytes)\(item.id == group.suggestedKeeperID ? ", best quality" : "")")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}
