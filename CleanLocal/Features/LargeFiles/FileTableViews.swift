import SwiftUI

/// Sortable table of files from the disk analysis, with Quick Look and safe removal.
struct FileNodeTable: View {
    let nodes: [DiskNode]
    @Binding var selection: Set<DiskNode.ID>
    @State private var sortOrder = [KeyPathComparator(\DiskNode.allocatedSize, order: .reverse)]
    @State private var previewURL: URL?

    var body: some View {
        let sorted = nodes.sorted(using: sortOrder)
        Table(sorted, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { node in
                HStack(spacing: Spacing.s) {
                    FileThumbnailView(url: URL(fileURLWithPath: node.path), size: 26)
                    Text(node.name).lineLimit(1).truncationMode(.middle)
                }
            }
            .width(min: 200, ideal: 300)
            TableColumn("Kind") { Label($0.category.title, systemImage: $0.category.symbolName).foregroundStyle(.secondary) }
                .width(min: 90, ideal: 110)
            TableColumn("Size", value: \.logicalSize) { Text($0.logicalSize.formattedBytes).monospacedDigit() }
                .width(min: 70, ideal: 80)
            TableColumn("On Disk", value: \.allocatedSize) { Text($0.allocatedSize.formattedBytes).monospacedDigit().foregroundStyle(.secondary) }
                .width(min: 70, ideal: 80)
            TableColumn("Frees", value: \.reclaimableSize) { node in
                Text(node.reclaimableSize.formattedBytes)
                    .monospacedDigit()
                    .foregroundStyle(node.reclaimableSize < node.allocatedSize / 2 ? AnyShapeStyle(Palette.blaze) : AnyShapeStyle(.secondary))
                    .help(node.reclaimableSize < node.allocatedSize / 2 ? "Shared with a clone or hard link — removing this copy frees less." : "")
            }
            .width(min: 70, ideal: 80)
            TableColumn("Modified") { Text($0.modified?.shortDisplay ?? "—").foregroundStyle(.secondary) }
                .width(min: 90, ideal: 110)
            TableColumn("Location") { node in
                Text(UserDirectories.abbreviate(path: (node.path as NSString).deletingLastPathComponent))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            .width(min: 140, ideal: 260)
        }
        .contextMenu(forSelectionType: DiskNode.ID.self) { ids in
            let chosen = sorted.filter { ids.contains($0.id) }
            if let first = chosen.first {
                Button("Quick Look", systemImage: "eye") { previewURL = URL(fileURLWithPath: first.path) }
                Button("Reveal in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting(chosen.map { URL(fileURLWithPath: $0.path) })
                }
            }
        } primaryAction: { ids in
            previewURL = sorted.first { ids.contains($0.id) }.map { URL(fileURLWithPath: $0.path) }
        }
        .onKeyPress(.space) {
            guard let first = sorted.first(where: { selection.contains($0.id) }) else { return .ignored }
            previewURL = URL(fileURLWithPath: first.path)
            return .handled
        }
        .quickLook($previewURL, in: sorted.map { URL(fileURLWithPath: $0.path) })
    }
}

/// Shared frame for Large Files and Old Files: access → analysis → filtered table.
struct FileListScreen<Filters: View>: View {
    let title: String
    let subtitle: String
    let nodes: [DiskNode]
    @ViewBuilder var filters: () -> Filters

    @Environment(AccessStore.self) private var access
    @Environment(StorageStore.self) private var store
    @Environment(CleanupStore.self) private var cleanup
    @State private var selection = Set<DiskNode.ID>()

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                PageHeader(title: title, subtitle: store.tree == nil ? subtitle : "\(nodes.count.formatted()) files · \(nodes.reduce(Int64(0)) { $0 + $1.allocatedSize }.formattedBytes)") {
                    DiskScanControls()
                }
                if case let .scanning(progress) = store.phase { DiskScanProgressCard(progress: progress) }
                if store.tree != nil { filters() }
            }
            .padding(.horizontal, Spacing.xxl)
            .padding(.top, Spacing.xl)
            .padding(.bottom, Spacing.m)
            Divider().opacity(0.6)

            if !access.hasHomeAccess {
                AccessRequiredView(kind: .home)
            } else if store.tree == nil {
                EmptyStateView(symbol: "externaldrive", title: "Analyze Your Home Folder",
                               message: "One analysis powers Storage Analyzer, Large Files, Old Files and duplicate search.") {
                    Button("Analyze Now") { store.scan() }.buttonStyle(.primaryLarge).disabled(store.isScanning)
                }
            } else if nodes.isEmpty {
                EmptyStateView(symbol: "checkmark.seal.fill", title: "Nothing Matches", message: "Try a smaller size or a different age.", tint: Palette.accent)
            } else {
                FileNodeTable(nodes: nodes, selection: $selection)
            }
        }
        .background(Palette.pageBackground)
        .overlay(alignment: .bottom) {
            let selected = nodes.filter { selection.contains($0.id) }
            if !selected.isEmpty {
                SelectionActionBar(
                    count: selected.count,
                    bytes: selected.reduce(0) { $0 + $1.logicalSize },
                    canReveal: true,
                    onPreview: nil,
                    onReveal: { NSWorkspace.shared.activateFileViewerSelecting(selected.map { URL(fileURLWithPath: $0.path) }) },
                    onDeselect: { selection.removeAll() },
                    onMoveToTrash: { cleanup.reviewCleanup(store.candidates(for: selected)) }
                )
                .padding(.bottom, Spacing.xl)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.cleanLocalSpring, value: selection.isEmpty)
        .onChange(of: store.removedPaths) { selection.formIntersection(Set(nodes.map(\.id))) }
    }
}

/// Every large file in your Home folder (not just media).
struct LargeFilesView: View {
    private static let presets: [Int64?] = [10, 50, 100, 500, 1_000, nil]
    @Environment(StorageStore.self) private var store
    @State private var presetMB: Int64? = 100
    @State private var customMB: Int64 = 250
    @State private var category: FileCategory?

    var body: some View {
        let minimum = (presetMB ?? max(customMB, 1)) * 1_000_000
        let nodes = store.visibleFiles.filter { $0.logicalSize >= minimum && (category == nil || $0.category == category) }
        FileListScreen(title: "Large Files", subtitle: "The biggest files in your Home folder, of every kind", nodes: nodes) {
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack(spacing: Spacing.m) {
                    ChipPicker(options: Self.presets, selection: $presetMB) { value in
                        guard let value else { return "Custom" }
                        return value >= 1_000 ? "> \(value / 1_000) GB" : "> \(value) MB"
                    }
                    if presetMB == nil {
                        TextField("MB", value: $customMB, format: .number).textFieldStyle(.roundedBorder).frame(width: 80)
                        Text("MB").foregroundStyle(.secondary)
                    }
                }
                ChipPicker(options: [nil] + FileCategory.allCases.map(Optional.some), selection: $category) { $0?.title ?? "All Kinds" }
            }
        }
    }
}

/// Files that haven't changed in a long time (outside ~/Library).
struct OldFilesView: View {
    private static let ages = [1, 2, 3, 5]
    @Environment(StorageStore.self) private var store
    @Environment(NavigationModel.self) private var navigation
    @State private var years = 2

    var body: some View {
        let cutoff = Calendar.current.date(byAdding: .year, value: -years, to: .now) ?? .now
        let nodes = store.visibleFiles.filter { node in
            (node.modified.map { $0 < cutoff } ?? false) && !node.path.contains("/Library/")
        }
        FileListScreen(title: "Old Files", subtitle: "Files over 1 MB you haven’t changed in years", nodes: nodes) {
            HStack(spacing: Spacing.m) {
                ChipPicker(options: Self.ages, selection: $years) { "Older than \($0) \($0 == 1 ? "year" : "years")" }
                Spacer()
                Button("Old Photos & Videos…") { navigation.showMedia(.oldMedia) }.buttonStyle(.link)
            }
            InfoBanner(style: .info, message: "Old isn’t the same as unneeded — these are listed for your review only. App data in ~/Library is excluded.")
        }
    }
}
