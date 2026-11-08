import SwiftUI

struct DuplicatesView: View {
    @Environment(AnalysisStore.self) private var analysis
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
        .onChange(of: analysis.duplicateGroups.map(\.id)) {
            let valid = Set(analysis.duplicateGroups.flatMap { $0.items.map(\.id) })
            selection.formIntersection(valid)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            PageHeader(title: "Duplicate Media", subtitle: subtitle) {
                HStack(spacing: Spacing.s) {
                    if !analysis.duplicateGroups.isEmpty {
                        Button("Select Suggested") {
                            selection = DuplicateSelectionPolicy.autoSelection(for: analysis.duplicateGroups)
                        }
                        .buttonStyle(.glass)
                        .help("Selects every copy except the suggested keeper in each group")
                    }
                    Button(analysis.duplicatePhase == .notStarted ? "Find Duplicates" : "Analyze Again") {
                        analysis.analyzeDuplicates()
                    }
                    .buttonStyle(.primary)
                    .disabled(analysis.duplicatePhase.isRunning || library.items.isEmpty)
                }
            }
            if case let .running(progress, message) = analysis.duplicatePhase {
                AnalysisProgressView(message: message, fraction: progress) { analysis.cancelDuplicateAnalysis() }
            }
            InfoBanner(
                style: .privacy,
                message: "Duplicates are confirmed byte-for-byte with SHA-256, on this Mac. “Select Suggested” always keeps one copy per group; nothing is removed until you confirm."
            )
        }
        .padding(.horizontal, Spacing.xxl)
        .padding(.top, Spacing.xl)
        .padding(.bottom, Spacing.m)
    }

    private var subtitle: String {
        switch analysis.duplicatePhase {
        case .notStarted: "Not analyzed yet"
        case .running: "Analyzing…"
        case let .failed(message): "Analysis failed: \(message)"
        case .completed:
            "\(analysis.duplicateGroups.count) groups · \(analysis.redundantCopyCount) extra copies · \(analysis.reclaimableDuplicateBytes.formattedBytes) reclaimable"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch analysis.duplicatePhase {
        case .notStarted where analysis.duplicateGroups.isEmpty:
            EmptyStateView(
                symbol: "square.on.square",
                title: "Find Identical Copies",
                message: "CleanLocal compares file sizes first, then verifies candidates with SHA-256 so only truly identical files are grouped."
            ) {
                Button("Find Duplicates") { analysis.analyzeDuplicates() }
                    .buttonStyle(.primaryLarge)
                    .disabled(library.items.isEmpty)
            }
        case .completed where analysis.duplicateGroups.isEmpty:
            EmptyStateView(
                symbol: "checkmark.seal.fill",
                title: "No Duplicates Found",
                message: analysis.unreadableDuplicateCandidates > 0
                    ? "\(analysis.unreadableDuplicateCandidates) candidates couldn’t be read (for example, originals stored only in iCloud)."
                    : "Every scanned file is unique.",
                tint: Palette.success
            )
        default:
            ScrollView {
                LazyVStack(spacing: Spacing.l) {
                    ForEach(analysis.duplicateGroups) { group in
                        DuplicateGroupCard(group: group, selection: $selection)
                    }
                }
                .padding(Spacing.xxl)
                .padding(.bottom, 72)
            }
        }
    }

    private var selectedItems: [MediaItem] {
        var seen = Set<MediaItem.ID>()
        return analysis.duplicateGroups.flatMap(\.items).filter { selection.contains($0.id) && seen.insert($0.id).inserted }
    }
}

/// One group of byte-identical files.
struct DuplicateGroupCard: View {
    let group: DuplicateGroup
    @Binding var selection: Set<MediaItem.ID>
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(group.items.count) identical copies")
                        .font(.cardTitle)
                    Text("\(group.items.first?.size.formattedBytes ?? "") each · \(group.reclaimableBytes.formattedBytes) reclaimable")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if allSelected {
                    Label("Every copy selected", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.warning)
                }
                Button("Keep Suggested") {
                    let others = group.items.filter { $0.id != group.suggestedKeeperID }.map(\.id)
                    selection.remove(group.suggestedKeeperID)
                    selection.formUnion(others)
                }
                .buttonStyle(.glass)
                .help("Select every copy except the suggested one")
            }

            VStack(spacing: 0) {
                ForEach(group.items) { item in
                    DuplicateRow(
                        item: item,
                        isKeeper: item.id == group.suggestedKeeperID,
                        isSelected: selection.contains(item.id),
                        toggle: { toggle(item) },
                        preview: { openWindow(id: MediaPreviewScene.id, value: item.id) }
                    )
                    if item.id != group.items.last?.id { Divider().padding(.leading, 96) }
                }
            }
            .background(RoundedRectangle(cornerRadius: Radius.medium).fill(Palette.subtleFill))
            .clipShape(RoundedRectangle(cornerRadius: Radius.medium))
        }
        .card(padding: Spacing.l)
    }

    private var allSelected: Bool { group.items.allSatisfy { selection.contains($0.id) } }

    private func toggle(_ item: MediaItem) {
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
    }
}

private struct DuplicateRow: View {
    let item: MediaItem
    let isKeeper: Bool
    let isSelected: Bool
    let toggle: () -> Void
    let preview: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Spacing.m) {
            Toggle("Select \(item.filename)", isOn: Binding(get: { isSelected }, set: { _ in toggle() }))
                .toggleStyle(.checkbox)
                .labelsHidden()
            ThumbnailView(item: item, pixelSize: 160)
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .onTapGesture(count: 2, perform: preview)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Spacing.xs) {
                    Text(item.filename).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    if isKeeper { Badge(text: "Suggested Keep", symbol: "star.fill", tint: Palette.success) }
                    if item.isPhotosAsset { Badge(text: "Photos", tint: Palette.brandViolet) }
                }
                Text(item.locationDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(item.path ?? "Photos Library")
                HStack(spacing: Spacing.m) {
                    if let dimensions = item.dimensionsDescription { Text(dimensions) }
                    Text(item.creationDate?.shortDisplay ?? item.effectiveDate.shortDisplay)
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
            Spacer()
            Text(item.size.formattedBytes).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            HStack(spacing: Spacing.xxs) {
                Button("Quick Look", systemImage: "eye", action: preview)
                if !item.isPhotosAsset {
                    Button("Reveal in Finder", systemImage: "folder") { FinderActions.reveal([item]) }
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .opacity(isHovering ? 1 : 0.4)
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
        .background(isSelected ? Color.accentColor.opacity(0.08) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
