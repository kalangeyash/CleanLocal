import SwiftUI

/// The central "scan everything, review, clean" experience.
struct SmartCleanupView: View {
    @Environment(AccessStore.self) private var access
    @Environment(CleanupStore.self) private var cleanup

    var body: some View {
        Group {
            if !access.hasHomeAccess {
                AccessRequiredView(kind: .home)
            } else {
                CleanupResultsView(
                    title: "Smart Cleanup",
                    subtitle: "Every category in one pass. Safe items are pre-selected; review items never are.",
                    candidates: cleanup.candidates,
                    showsGroupHeaders: true,
                    showsMediaRecommendations: true
                )
            }
        }
        .background(Palette.pageBackground)
    }
}

/// One cleanup module (System Junk, Application Cache, Browser, Developer…).
struct CleanupModuleView: View {
    let destination: SidebarDestination
    @Environment(AccessStore.self) private var access
    @Environment(CleanupStore.self) private var cleanup

    var body: some View {
        Group {
            if !access.hasHomeAccess {
                AccessRequiredView(kind: .home)
            } else {
                CleanupResultsView(
                    title: destination.title,
                    subtitle: subtitle,
                    candidates: candidates,
                    showsGroupHeaders: (destination.cleanupGroups?.count ?? 0) > 1,
                    showsMediaRecommendations: false
                ) {
                    moduleAccessory
                }
            }
        }
        .background(Palette.pageBackground)
    }

    private var candidates: [CleanupCandidate] {
        if destination == .leftovers { return cleanup.leftoverCandidates }
        let groups = Set(destination.cleanupGroups ?? [])
        return cleanup.candidates.filter { CleanupCatalog.category(id: $0.categoryID).map { groups.contains($0.group) } ?? false }
    }

    private var subtitle: String {
        switch destination {
        case .systemJunk: "Old logs, crash reports and saved window state from ~/Library."
        case .applicationCache: "Rebuildable caches, grouped by app. Running apps are skipped."
        case .temporaryFiles: "Unfinished downloads, temporary folders and installers you may not need."
        case .browserCleanup: "Only cached web files. Sign-ins, cookies, history, bookmarks and tabs are never touched."
        case .developerCleanup: "Rebuildable build outputs and package caches. Source code is never touched."
        case .leftovers: "Data from apps that are no longer installed. Most of it needs your review."
        default: ""
        }
    }

    @ViewBuilder
    private var moduleAccessory: some View {
        switch destination {
        case .temporaryFiles:
            InfoBanner(style: .info, title: "About the system temporary folder",
                       message: "macOS manages its own temporary folder ($TMPDIR, inside /private/var) and removes files there that haven’t been used for three days. It’s protected, so CleanLocal leaves it to macOS.")
        case .developerCleanup:
            DeveloperFoldersBanner()
        case .leftovers:
            InstalledAppsSummary()
        default:
            EmptyView()
        }
    }
}

/// Shared results UI for Smart Cleanup and every module.
struct CleanupResultsView<Accessory: View>: View {
    let title: String
    let subtitle: String
    let candidates: [CleanupCandidate]
    let showsGroupHeaders: Bool
    let showsMediaRecommendations: Bool
    @ViewBuilder var accessory: () -> Accessory

    @Environment(CleanupStore.self) private var cleanup
    @State private var previewURL: URL?
    @State private var levelFilter: SafetyLevel?

    init(title: String, subtitle: String, candidates: [CleanupCandidate], showsGroupHeaders: Bool, showsMediaRecommendations: Bool,
         @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.candidates = candidates
        self.showsGroupHeaders = showsGroupHeaders
        self.showsMediaRecommendations = showsMediaRecommendations
        self.accessory = accessory
    }

    var body: some View {
        @Bindable var cleanup = cleanup
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                PageHeader(title: title, subtitle: subtitle) { scanControls }
                accessory()
                switch cleanup.phase {
                case let .scanning(progress):
                    scanningCard(progress)
                case .idle:
                    EmptyStateView(symbol: "sparkle.magnifyingglass", title: "Ready to Scan",
                                   message: "CleanLocal looks only in verified locations and explains every finding. Nothing is removed until you review and confirm.") {
                        Button("Scan Now") { cleanup.scan() }.buttonStyle(.primaryLarge)
                    }
                    .frame(minHeight: 320)
                case .ready:
                    results
                }
                if let issues = cleanup.result?.issues, !issues.isEmpty {
                    InfoBanner(style: .info, title: "\(issues.count) locations couldn’t be read",
                               message: issues.prefix(4).map { "\(UserDirectories.abbreviate(path: $0.path)) — \($0.reason)" }.joined(separator: "\n")
                                   + "\nmacOS protects these; CleanLocal skips them rather than working around the protection.")
                }
            }
            .padding(Spacing.xxl)
            .padding(.bottom, 80)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .overlay(alignment: .bottom) {
            let selected = candidates.filter { cleanup.selection.contains($0.id) && $0.isSelectable }
            if !selected.isEmpty {
                CleanupSelectionBar(count: selected.count, bytes: selected.reduce(0) { $0 + $1.size.logicalSize }) {
                    cleanup.reviewCleanup(selected)
                }
                .padding(.bottom, Spacing.xl)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.cleanLocalSpring, value: cleanup.selection.isEmpty)
        .quickLook($previewURL, in: candidates.map(\.url))
        .task {
            if cleanup.phase == .idle { cleanup.scan() }
        }
    }

    private var scanControls: some View {
        HStack(spacing: Spacing.s) {
            if cleanup.isScanning {
                Button("Stop") { cleanup.cancelScan() }.buttonStyle(.glass)
            } else {
                Button(cleanup.result == nil ? "Scan" : "Rescan") { cleanup.scan() }
                    .buttonStyle(.primary)
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }

    private func scanningCard(_ progress: CleanupScanProgress) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack {
                Text("Scanning \(progress.categoryTitle)…").font(.headline)
                Spacer()
                Text("\(progress.itemsFound) found · \(progress.bytesFound.formattedBytes)")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary).contentTransition(.numericText())
            }
            ProgressView(value: progress.fraction)
            // Skeleton rows while results arrive.
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: Radius.medium).fill(Palette.subtleFill).frame(height: 54)
            }
        }
        .card(padding: Spacing.xl)
    }

    @ViewBuilder
    private var results: some View {
        let visible = levelFilter.map { level in candidates.filter { $0.safety == level } } ?? candidates
        summaryStrip
        if candidates.isEmpty {
            EmptyStateView(symbol: "checkmark.seal.fill", title: "Nothing to Clean Here",
                           message: "No eligible items were found in this area.", tint: Palette.accent)
                .frame(minHeight: 260)
        } else if showsGroupHeaders {
            ForEach(CleanupGroup.allCases) { group in
                let inGroup = visible.filter { CleanupCatalog.category(id: $0.categoryID)?.group == group }
                if !inGroup.isEmpty {
                    Text(group.title).font(.title3.weight(.semibold)).padding(.top, Spacing.s)
                    categorySections(inGroup)
                }
            }
        } else {
            categorySections(visible)
        }
        if showsMediaRecommendations { MediaRecommendations() }
    }

    private func categorySections(_ list: [CleanupCandidate]) -> some View {
        @Bindable var cleanup = cleanup
        let byCategory = Dictionary(grouping: list, by: \.categoryID)
            .compactMap { id, items in CleanupCatalog.category(id: id).map { ($0, items) } }
            .sorted { lhs, rhs in
                let lhsLevel = lhs.1.map(\.safety).min() ?? .protected, rhsLevel = rhs.1.map(\.safety).min() ?? .protected
                if lhsLevel != rhsLevel { return lhsLevel < rhsLevel }
                return lhs.1.reduce(0) { $0 + $1.size.logicalSize } > rhs.1.reduce(0) { $0 + $1.size.logicalSize }
            }
        return ForEach(byCategory, id: \.0.id) { category, items in
            CategorySection(category: category, candidates: items, selection: $cleanup.selection, previewURL: $previewURL)
        }
    }

    private var summaryStrip: some View {
        HStack(spacing: Spacing.m) {
            ForEach(SafetyLevel.allCases, id: \.self) { level in
                let items = candidates.filter { $0.safety == level }
                Button {
                    withAnimation(.cleanLocalSpring) { levelFilter = levelFilter == level ? nil : level }
                } label: {
                    HStack(spacing: Spacing.s) {
                        Image(systemName: level.symbolName)
                            .foregroundStyle(Palette.onBrand)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(level.tint))
                        VStack(alignment: .leading, spacing: 0) {
                            Text(items.reduce(Int64(0)) { $0 + $1.size.logicalSize }.formattedBytes)
                                .font(.system(.headline, design: .rounded).monospacedDigit())
                            Text("\(level.title) · \(items.count)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(Spacing.m)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                        .fill(levelFilter == level ? level.tint.opacity(0.18) : Palette.cardBackground))
                    .overlay(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                        .strokeBorder(levelFilter == level ? level.tint : Palette.cardStroke))
                }
                .buttonStyle(.plain)
                .help("Show only \(level.title.lowercased()) items")
            }
        }
    }
}

/// Media findings in Smart Cleanup link to the review screens (never cleaned inline).
private struct MediaRecommendations: View {
    @Environment(AnalysisStore.self) private var analysis
    @Environment(LibraryStore.self) private var library
    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: .now) ?? .now
        let oldScreenshots = library.items.filter { $0.isScreenshot && $0.effectiveDate < cutoff }
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("Media").font(.title3.weight(.semibold)).padding(.top, Spacing.s)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: Spacing.l)], spacing: Spacing.l) {
                QuickActionCard(title: "Duplicate Photos & Videos",
                                detail: analysis.duplicateGroups.isEmpty ? "Scan media to find copies" : "\(analysis.reclaimableDuplicateBytes.formattedBytes) in extra copies · Review",
                                symbol: "square.on.square.fill", tint: Palette.tangerine) {
                    navigation.duplicateTab = .media
                    navigation.destination = .duplicates
                }
                QuickActionCard(title: "Old Screenshots",
                                detail: "\(oldScreenshots.count) older than 90 days · \(StorageAnalyticsService.totalSize(of: oldScreenshots).formattedBytes)",
                                symbol: "camera.viewfinder", tint: Palette.khaki) { navigation.showMedia(.screenshots) }
                QuickActionCard(title: "Trash", detail: "Empty it from the Trash Manager", symbol: "trash.fill", tint: Palette.grey) {
                    navigation.destination = .trashManager
                }
            }
        }
    }
}

/// Developer folders searched for node_modules and build outputs.
private struct DeveloperFoldersBanner: View {
    @Environment(AccessStore.self) private var access
    @Environment(CleanupStore.self) private var cleanup

    var body: some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: "folder.badge.gearshape").font(.title2).foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(access.developerFolders.isEmpty ? "Add your project folders" : "Searching \(access.developerFolders.count) project folders")
                    .font(.headline)
                Text(access.developerFolders.isEmpty
                     ? "CleanLocal never searches your whole disk for node_modules. Choose the folders where you keep code."
                     : access.developerFolders.map { UserDirectories.abbreviate(path: $0.path) }.joined(separator: ", "))
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button("Add Folders…") {
                access.addDeveloperFolders()
                cleanup.scan()
            }
            .buttonStyle(.glass)
        }
        .card(padding: Spacing.m)
    }
}

/// Installed apps with their related cache/support sizes (from the last scan).
private struct InstalledAppsSummary: View {
    @Environment(CleanupStore.self) private var cleanup
    @State private var isExpanded = false

    var body: some View {
        let related = Dictionary(grouping: cleanup.candidates.filter { $0.owner?.isInstalled == true }) { $0.owner?.bundleID ?? "" }
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(spacing: 0) {
                ForEach(cleanup.installedApps.prefix(200)) { app in
                    let items = related[app.bundleID] ?? []
                    HStack(spacing: Spacing.m) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 24, height: 24)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(app.name).font(.callout)
                            Text("\(app.bundleID)\(app.version.map { " · \($0)" } ?? "")").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(items.isEmpty ? "—" : "\(items.reduce(Int64(0)) { $0 + $1.size.logicalSize }.formattedBytes) cache & data")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 5)
                    Divider()
                }
            }
            .padding(.top, Spacing.s)
        } label: {
            Label("\(cleanup.installedApps.count) installed apps", systemImage: "app.badge.checkmark").font(.headline)
        }
        .card(padding: Spacing.m)
    }
}
