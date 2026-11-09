import SwiftUI

/// All media tools in one place: library, videos, screenshots, similar photos and more.
struct MediaCleanerView: View {
    @Environment(NavigationModel.self) private var navigation
    @Environment(LibraryStore.self) private var library

    var body: some View {
        @Bindable var navigation = navigation
        VStack(spacing: 0) {
            HStack(spacing: Spacing.xs) {
                ForEach(MediaTab.allCases) { tab in
                    Button {
                        withAnimation(.cleanLocalSpring) { navigation.mediaTab = tab }
                    } label: {
                        Label(tab.title, systemImage: tab.symbolName)
                            .font(.callout.weight(navigation.mediaTab == tab ? .semibold : .regular))
                            .foregroundStyle(navigation.mediaTab == tab ? Palette.onBrand : Palette.ink)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(navigation.mediaTab == tab ? AnyShapeStyle(Palette.brandGradient) : AnyShapeStyle(Color.clear)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(navigation.mediaTab == tab ? .isSelected : [])
                }
                Spacer()
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.s)
            .background(.bar)
            Divider()

            Group {
                if !library.hasSources && navigation.mediaTab != .photosLibrary {
                    OnboardingView()
                } else {
                    switch navigation.mediaTab {
                    case .library: AllMediaView()
                    case .videos: VideosView()
                    case .screenshots: ScreenshotsView()
                    case .similar: SimilarPhotosView()
                    case .largeMedia: LargeMediaView()
                    case .oldMedia: OldMediaView()
                    case .photosLibrary: PhotosLibraryView()
                    case .recentlyScanned: RecentlyScannedView()
                    }
                }
            }
            .id(navigation.mediaTab)
        }
    }
}

/// Duplicate photos/videos (media index) and duplicate files of any type (disk analysis).
struct DuplicateFinderView: View {
    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        @Bindable var navigation = navigation
        VStack(spacing: 0) {
            Picker("Duplicates", selection: $navigation.duplicateTab) {
                ForEach(DuplicateTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)
            .padding(.vertical, Spacing.s)
            .frame(maxWidth: .infinity)
            .background(.bar)
            Divider()
            switch navigation.duplicateTab {
            case .media: DuplicatesView()
            case .files: FileDuplicatesView()
            }
        }
    }
}

/// Byte-identical files of any type, clone-aware.
struct FileDuplicatesView: View {
    @Environment(AccessStore.self) private var access
    @Environment(StorageStore.self) private var store
    @Environment(CleanupStore.self) private var cleanup
    @State private var selection = Set<String>()
    @State private var previewURL: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                PageHeader(title: "Duplicate Files", subtitle: subtitle) {
                    HStack(spacing: Spacing.s) {
                        if !store.duplicateGroups.isEmpty {
                            Button("Select Extra Copies") {
                                selection = Set(store.duplicateGroups.flatMap { group in group.files.filter { $0.path != group.keeperPath }.map(\.path) })
                            }
                            .buttonStyle(.glass)
                        }
                        if store.tree == nil { DiskScanControls() } else {
                            Button(store.duplicatesPhase == .notStarted ? "Find Duplicates" : "Search Again") { store.findDuplicates() }
                                .buttonStyle(.primary)
                                .disabled(store.duplicatesPhase.isRunning)
                        }
                    }
                }
                if case let .running(progress, message) = store.duplicatesPhase {
                    AnalysisProgressView(message: message, fraction: progress)
                }
                InfoBanner(style: .privacy, message: "Files over 1 MB in your Home folder (outside ~/Library) are compared by size, then fingerprint, then SHA-256. Copies that are APFS clones share disk space, so removing them frees little — they’re marked.")
                if !access.hasHomeAccess {
                    AccessRequiredView(kind: .home).frame(minHeight: 280).card()
                } else if store.tree == nil {
                    EmptyStateView(symbol: "square.on.square", title: "Analyze Your Home Folder First",
                                   message: "Duplicate search uses the same analysis as the Storage Analyzer.") {
                        Button("Analyze Now") { store.scan() }.buttonStyle(.primaryLarge).disabled(store.isScanning)
                    }
                    .frame(minHeight: 280)
                } else if case .completed = store.duplicatesPhase, store.duplicateGroups.isEmpty {
                    EmptyStateView(symbol: "checkmark.seal.fill", title: "No Duplicate Files", message: "Every large file is unique.", tint: Palette.accent)
                        .frame(minHeight: 240)
                }
                ForEach(store.duplicateGroups) { group in groupCard(group) }
            }
            .padding(Spacing.xxl)
            .padding(.bottom, 80)
        }
        .background(Palette.pageBackground)
        .overlay(alignment: .bottom) {
            let selected = store.visibleFiles.filter { selection.contains($0.path) }
            if !selected.isEmpty {
                SelectionActionBar(
                    count: selected.count, bytes: selected.reduce(0) { $0 + $1.reclaimableSize }, canReveal: true, onPreview: nil,
                    onReveal: { NSWorkspace.shared.activateFileViewerSelecting(selected.map { URL(fileURLWithPath: $0.path) }) },
                    onDeselect: { selection.removeAll() },
                    onMoveToTrash: { cleanup.reviewCleanup(store.candidates(for: selected)) }
                )
                .padding(.bottom, Spacing.xl)
            }
        }
        .quickLook($previewURL, in: store.duplicateGroups.flatMap { $0.files.map { URL(fileURLWithPath: $0.path) } })
        .onChange(of: store.removedPaths) { selection.subtract(store.removedPaths) }
    }

    private var subtitle: String {
        guard case .completed = store.duplicatesPhase else { return "Identical files of any type" }
        let reclaimable = store.duplicateGroups.reduce(Int64(0)) { $0 + $1.reclaimableBytes }
        return "\(store.duplicateGroups.count) groups · \(reclaimable.formattedBytes) actually reclaimable"
    }

    private func groupCard(_ group: FileDuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack {
                Text("\(group.files.count) identical copies · \(group.files.first?.logicalSize.formattedBytes ?? "") each").font(.headline)
                if group.involvesClones { Badge(text: "APFS clones", symbol: "square.on.square.dashed", tint: Palette.khaki) }
                Spacer()
                Text("frees \(group.reclaimableBytes.formattedBytes)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            ForEach(group.files) { node in
                HStack(spacing: Spacing.m) {
                    Toggle("Select", isOn: Binding(
                        get: { selection.contains(node.path) },
                        set: { if $0 { selection.insert(node.path) } else { selection.remove(node.path) } }
                    ))
                    .toggleStyle(.checkbox).labelsHidden()
                    FileThumbnailView(url: URL(fileURLWithPath: node.path), size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: Spacing.xs) {
                            Text(node.name).font(.callout).lineLimit(1)
                            if node.path == group.keeperPath { Badge(text: "Suggested Keep", symbol: "star.fill", tint: Palette.success) }
                        }
                        Text(UserDirectories.abbreviate(path: (node.path as NSString).deletingLastPathComponent))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                    Spacer()
                    Text(node.modified?.shortDisplay ?? "").font(.caption).foregroundStyle(.secondary)
                    Button("Quick Look", systemImage: "eye") { previewURL = URL(fileURLWithPath: node.path) }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                }
            }
        }
        .card(padding: Spacing.l)
    }
}
