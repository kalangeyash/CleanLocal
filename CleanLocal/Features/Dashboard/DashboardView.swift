import SwiftUI

struct DashboardView: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        if !library.isLoaded {
            ProgressView("Loading your library…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !library.hasSources {
            OnboardingView()
        } else {
            DashboardContent()
        }
    }
}

private struct DashboardContent: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AnalysisStore.self) private var analysis
    @Environment(SettingsStore.self) private var settings
    @Environment(NavigationModel.self) private var navigation
    @Environment(\.storageService) private var storage
    @State private var highlighted: MediaCategory?
    @State private var volume: VolumeCapacity?

    private let statColumns = [GridItem(.adaptive(minimum: 190), spacing: Spacing.l)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                DashboardHero()
                statsGrid
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: Spacing.l) {
                        breakdownCard.frame(minWidth: 420)
                        sideColumn.frame(minWidth: 300, maxWidth: 380)
                    }
                    VStack(spacing: Spacing.l) {
                        breakdownCard
                        sideColumn
                    }
                }
                quickActions
                if !library.lastScanIssues.isEmpty {
                    InfoBanner(
                        style: .warning,
                        title: "\(library.lastScanIssues.count) items couldn’t be read during the last scan",
                        message: library.lastScanIssues.prefix(3).map { "\(UserDirectories.abbreviate(path: $0.path)) — \($0.reason)" }.joined(separator: "\n")
                    )
                }
            }
            .padding(Spacing.xxl)
            .frame(maxWidth: 1200)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.pageBackground)
        .task(id: library.revision) { volume = storage.startupVolume() }
    }

    // MARK: Stats

    private var largeFiles: [MediaItem] {
        library.items.filter { $0.size >= settings.largeFileThresholdBytes }
    }

    private var statsGrid: some View {
        let breakdown = library.breakdown
        let large = largeFiles
        let duplicatesAnalyzed: Bool = if case .completed = analysis.duplicatePhase { true } else { false }
        return LazyVGrid(columns: statColumns, spacing: Spacing.l) {
            StatTile(title: "Total Media", value: breakdown.totalCount.formatted(),
                     caption: "\(library.locations.count) folders\(library.includesPhotosLibrary ? " + Photos" : "")",
                     symbol: "photo.on.rectangle.angled", tint: Palette.brandIndigo) { navigation.destination = .allMedia }
            StatTile(title: "Media Storage", value: breakdown.totalBytes.formattedBytes,
                     caption: "Scanned media size", symbol: "internaldrive.fill", tint: Palette.brandViolet) { navigation.destination = .storage }
            StatTile(title: "Photos", value: breakdown.photoCount.formatted(),
                     caption: "Including screenshots", symbol: "photo.fill", tint: MediaCategory.photos.tint) { navigation.destination = .allMedia }
            StatTile(title: "Videos", value: breakdown.videoCount.formatted(),
                     caption: breakdown.entry(for: .videos).bytes.formattedBytes, symbol: "film.fill", tint: MediaCategory.videos.tint) { navigation.destination = .videos }
            StatTile(title: "Duplicate Files", value: duplicatesAnalyzed ? analysis.redundantCopyCount.formatted() : "—",
                     caption: duplicatesAnalyzed ? "\(analysis.duplicateGroups.count) groups of identical files" : "Not analyzed yet",
                     symbol: "square.on.square.fill", tint: Palette.warning) { navigation.destination = .duplicates }
            StatTile(title: "Large Files", value: large.count.formatted(),
                     caption: "Over \(settings.largeFileThresholdMB) MB · \(StorageAnalyticsService.totalSize(of: large).formattedBytes)",
                     symbol: "externaldrive.fill", tint: Palette.destructive) { navigation.destination = .largeFiles }
            StatTile(title: "Potential Savings", value: duplicatesAnalyzed ? analysis.reclaimableDuplicateBytes.formattedBytes : "—",
                     caption: "By removing extra duplicate copies", symbol: "leaf.fill", tint: Palette.success) { navigation.destination = .duplicates }
        }
    }

    // MARK: Breakdown

    private var breakdownCard: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            HStack {
                Text("Storage Breakdown").font(.cardTitle)
                Spacer()
                Text("\(library.breakdown.totalCount.formatted()) items")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if library.breakdown.totalBytes == 0 {
                Text("Run a scan to see how your media storage is distributed.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                HStack(spacing: Spacing.xl) {
                    StorageDonutChart(breakdown: library.breakdown, highlighted: $highlighted)
                        .frame(width: 210, height: 210)
                    CategoryLegend(breakdown: library.breakdown, highlighted: $highlighted) { category in
                        navigation.destination = switch category {
                        case .videos: .videos
                        case .screenshots: .screenshots
                        default: .allMedia
                        }
                    }
                }
            }
        }
        .card(padding: Spacing.xl)
    }

    private var sideColumn: some View {
        VStack(spacing: Spacing.l) {
            if let volume {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    Text("Startup Disk").font(.cardTitle)
                    CapacityBar(volume: volume, mediaBytes: library.breakdown.totalBytes)
                }
                .card(padding: Spacing.xl)
            }
            LocationsSummaryCard()
        }
    }

    // MARK: Quick actions

    private var quickActions: some View {
        let screenshots = library.breakdown.entry(for: .screenshots)
        let cutoff = settings.oldMediaThreshold.cutoff()
        let old = library.items.filter { $0.effectiveDate < cutoff }
        return VStack(alignment: .leading, spacing: Spacing.m) {
            Text("Suggested Reviews").font(.cardTitle)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: Spacing.l)], spacing: Spacing.l) {
                QuickActionCard(title: "Review Duplicates", detail: analysis.duplicateGroups.isEmpty ? "Find byte-identical copies" : "\(analysis.reclaimableDuplicateBytes.formattedBytes) in extra copies",
                                symbol: "square.on.square.fill", tint: Palette.warning) { navigation.destination = .duplicates }
                QuickActionCard(title: "Similar Photos", detail: analysis.similarGroups.isEmpty ? "Bursts, edits and near-copies" : "\(analysis.similarGroups.count) groups to review",
                                symbol: "rectangle.stack.fill", tint: Palette.brandViolet) { navigation.destination = .similar }
                QuickActionCard(title: "Clean Up Screenshots", detail: "\(screenshots.count.formatted()) screenshots · \(screenshots.bytes.formattedBytes)",
                                symbol: "camera.viewfinder", tint: MediaCategory.screenshots.tint) { navigation.destination = .screenshots }
                QuickActionCard(title: "Old Media", detail: "\(old.count.formatted()) items older than \(settings.oldMediaThreshold.title)",
                                symbol: "clock.arrow.circlepath", tint: Palette.brandIndigo) { navigation.destination = .oldMedia }
            }
        }
    }
}

/// The gradient hero with the primary scan action or live scan progress.
struct DashboardHero: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AnalysisStore.self) private var analysis

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.xl) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                if let progress = library.scanProgress {
                    scanningContent(progress)
                } else {
                    idleContent
                }
            }
            Spacer(minLength: 0)
            decoration
        }
        .padding(Spacing.xxl)
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Radius.xlarge, style: .continuous)
                .fill(Palette.heroGradient)
                .overlay(alignment: .topTrailing) {
                    Circle().fill(.white.opacity(0.10)).frame(width: 260).offset(x: 80, y: -120)
                }
                .clipShape(RoundedRectangle(cornerRadius: Radius.xlarge, style: .continuous))
                .shadow(color: Palette.brandViolet.opacity(0.3), radius: 20, y: 10)
        }
        .foregroundStyle(.white)
        .animation(.cleanLocalSpring, value: library.isScanning)
    }

    @ViewBuilder
    private var idleContent: some View {
        Text(library.lastScanSession == nil ? "Ready for your first scan" : "Your media at a glance")
            .font(.heroTitle)
        Text(subtitle)
            .font(.callout)
            .foregroundStyle(.white.opacity(0.85))
        HStack(spacing: Spacing.m) {
            Button {
                library.startScan()
            } label: {
                Label("Scan My Mac", systemImage: "sparkle.magnifyingglass")
            }
            .buttonStyle(HeroButtonStyle())
            .keyboardShortcut("r", modifiers: .command)
            if case let .running(progress, message) = analysis.duplicatePhase {
                HStack(spacing: Spacing.s) {
                    ProgressView(value: progress).progressViewStyle(.circular).controlSize(.small).tint(.white)
                    Text(message).font(.caption).foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        .padding(.top, Spacing.xs)
    }

    @ViewBuilder
    private func scanningContent(_ progress: ScanProgress) -> some View {
        Text(progress.phase.rawValue + "…")
            .font(.heroTitle)
            .contentTransition(.interpolate)
        HStack(spacing: Spacing.xl) {
            metric("\(progress.filesVisited.formatted())", "files checked")
            metric("\(progress.mediaFound.formatted())", "media found")
            if progress.metadataTotal > 0 {
                metric("\(progress.metadataProcessed.formatted())/\(progress.metadataTotal.formatted())", "analyzed")
            }
        }
        Group {
            if let fraction = progress.fractionCompleted {
                ProgressView(value: fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
        }
        .tint(.white)
        .frame(maxWidth: 420)
        HStack {
            Text(progress.currentLocationName.isEmpty ? progress.currentPath : "\(progress.currentLocationName) · \(progress.currentPath)")
                .font(.caption.monospaced())
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 420, alignment: .leading)
            Button("Stop") { library.cancelScan() }
                .buttonStyle(.glassOnGradient)
                .keyboardShortcut(".", modifiers: .command)
        }
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .semibold).monospacedDigit())
                .contentTransition(.numericText())
            Text(label).font(.caption).foregroundStyle(.white.opacity(0.8))
        }
    }

    private var subtitle: String {
        let sources = library.locations.count
        var parts: [String] = ["\(sources) \(sources == 1 ? "folder" : "folders")"]
        if library.includesPhotosLibrary { parts.append("Photos library") }
        if let last = library.lastScanSession {
            parts.append("last scanned \(last.finishedAt.relativeDisplay)")
        }
        return parts.joined(separator: " · ")
    }

    private var decoration: some View {
        ZStack {
            Image(systemName: "photo.stack.fill")
                .font(.system(size: 86, weight: .light))
                .foregroundStyle(.white.opacity(0.22))
                .rotationEffect(.degrees(-8))
            Image(systemName: "sparkles")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .offset(x: 52, y: -44)
                .symbolEffect(.pulse, isActive: library.isScanning)
        }
        .frame(width: 170)
        .accessibilityHidden(true)
    }
}

/// White capsule button for use on the hero gradient.
struct HeroButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.title3, design: .rounded, weight: .semibold))
            .foregroundStyle(Palette.brandIndigo)
            .padding(.horizontal, 22)
            .padding(.vertical, 11)
            .background(Capsule().fill(.white))
            .shadow(color: .black.opacity(0.15), radius: configuration.isPressed ? 2 : 8, y: 3)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.cleanLocalHover, value: configuration.isPressed)
    }
}

struct QuickActionCard: View {
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.m) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 42, height: 42)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(tint.opacity(0.13)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.right").foregroundStyle(.tertiary)
            }
            .card(padding: Spacing.m)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverLift()
    }
}

/// Compact list of scan locations with their availability.
struct LocationsSummaryCard: View {
    @Environment(LibraryStore.self) private var library
    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack {
                Text("Scan Locations").font(.cardTitle)
                Spacer()
                Button {
                    library.addLocations(LocationPicker.chooseFolders())
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.glass)
                .help("Add Folder (⌘O)")
                .accessibilityLabel("Add folder")
            }
            ForEach(library.locations.prefix(5)) { location in
                HStack(spacing: Spacing.s) {
                    Image(systemName: location.isRemovableVolume ? "externaldrive.fill" : "folder.fill")
                        .foregroundStyle(Palette.brandIndigo)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(location.displayName).lineLimit(1)
                        Text(UserDirectories.abbreviate(path: location.path))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer()
                    if case .unavailable = library.locationStatuses[location.id] {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning)
                            .help("Unavailable — the folder moved or the drive is disconnected")
                    }
                }
                .font(.callout)
            }
            if library.includesPhotosLibrary {
                Label("Photos Library", systemImage: "photo.stack.fill")
                    .font(.callout)
            }
            if library.locations.count > 5 {
                Button("Manage all \(library.locations.count) locations…") { navigation.destination = .settings }
                    .buttonStyle(.link)
            }
        }
        .card(padding: Spacing.xl)
    }
}
