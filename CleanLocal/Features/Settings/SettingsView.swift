import SwiftUI

/// Settings, shown both in the sidebar and in the standard Settings window (⌘,).
struct SettingsView: View {
    var embedded = false

    enum Tab: String, CaseIterable, Identifiable {
        case general, locations, fileTypes, detection, storage, privacy, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: "General"
            case .locations: "Locations"
            case .fileTypes: "File Types"
            case .detection: "Detection"
            case .storage: "Data & Cache"
            case .privacy: "Privacy"
            case .about: "About"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .locations: "folder"
            case .fileTypes: "doc.richtext"
            case .detection: "slider.horizontal.3"
            case .storage: "internaldrive"
            case .privacy: "lock.shield"
            case .about: "info.circle"
            }
        }
    }

    @AppStorage("settings.selectedTab") private var tab: Tab = .general

    var body: some View {
        TabView(selection: $tab) {
            ForEach(Tab.allCases) { tab in
                pane(for: tab)
                    .tabItem { Label(tab.title, systemImage: tab.symbol) }
                    .tag(tab)
            }
        }
        .padding(embedded ? Spacing.xl : 0)
        .frame(minWidth: 620, minHeight: 460)
        .background(embedded ? Palette.pageBackground : Color.clear)
    }

    @ViewBuilder
    private func pane(for tab: Tab) -> some View {
        switch tab {
        case .general: GeneralSettingsPane()
        case .locations: LocationsSettingsPane()
        case .fileTypes: FileTypesSettingsPane()
        case .detection: DetectionSettingsPane()
        case .storage: DataSettingsPane()
        case .privacy: PrivacySettingsPane()
        case .about: AboutPane()
        }
    }
}

private struct GeneralSettingsPane: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("Scanning") {
                Toggle("Find duplicates automatically after each scan", isOn: $settings.analyzeDuplicatesAfterScan)
                Toggle("Include hidden files and folders", isOn: $settings.includeHiddenFiles)
                Toggle("Include Photos library in scans", isOn: $settings.includePhotosLibrary)
            }
            Section {
                Button("Restore Default Settings") { settings.resetToDefaults() }
            }
        }
        .formStyle(.grouped)
    }
}

private struct LocationsSettingsPane: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        Form {
            Section {
                if library.locations.isEmpty {
                    Text("No folders yet. Add one to start scanning.").foregroundStyle(.secondary)
                }
                ForEach(library.locations) { location in
                    HStack(spacing: Spacing.m) {
                        Toggle(isOn: Binding(
                            get: { location.isEnabled },
                            set: { library.setLocation(location.id, enabled: $0) }
                        )) { EmptyView() }
                            .labelsHidden()
                            .help("Include in scans")
                        Image(systemName: location.isRemovableVolume ? "externaldrive.fill" : "folder.fill")
                            .foregroundStyle(Palette.brandIndigo)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(location.displayName)
                            Text(UserDirectories.abbreviate(path: location.path))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                            if case let .unavailable(reason) = library.locationStatuses[location.id] {
                                Text(reason).font(.caption).foregroundStyle(Palette.warning)
                            } else if let scanned = location.lastScannedAt {
                                Text("Scanned \(scanned.relativeDisplay) · \(library.items(in: location.id).count) items")
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        Button("Remove", role: .destructive) { library.removeLocation(location.id) }
                            .buttonStyle(.borderless)
                            .help("Stop scanning this folder. No files are touched.")
                    }
                }
            } header: {
                Text("Scan Locations")
            } footer: {
                Text("CleanLocal only scans folders you add here. System folders, app bundles and library packages are always skipped. Removing a location never deletes files.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Add") {
                LocationQuickPicks()
            }
            Section("Photos") {
                PhotosConnectRow()
            }
        }
        .formStyle(.grouped)
    }
}

private struct FileTypesSettingsPane: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        Form {
            Section("Images") {
                ForEach(MediaFormat.imageFormats) { toggle(for: $0) }
            }
            Section("Videos") {
                ForEach(MediaFormat.videoFormats) { toggle(for: $0) }
            }
            Section {
                HStack {
                    Button("Enable All") { settings.enabledFormats = Set(MediaFormat.allCases) }
                    Spacer()
                    Text("Changes apply to the next scan.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func toggle(for format: MediaFormat) -> some View {
        Toggle(isOn: Binding(
            get: { settings.enabledFormats.contains(format) },
            set: { enabled in
                if enabled { settings.enabledFormats.insert(format) } else { settings.enabledFormats.remove(format) }
            }
        )) {
            VStack(alignment: .leading, spacing: 1) {
                Text(format.displayName)
                Text(format.fileExtensions.sorted().map { ".\($0)" }.joined(separator: " "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

private struct DetectionSettingsPane: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                LabeledContent("Similarity threshold") {
                    HStack {
                        Slider(value: $settings.similarityThreshold, in: 0.80...0.98, step: 0.01)
                            .frame(width: 220)
                        Text("\(Int((settings.similarityThreshold * 100).rounded()))%").monospacedDigit().frame(width: 40)
                    }
                }
            } header: {
                Text("Similar Photos")
            } footer: {
                Text("Higher values only group photos that look nearly identical. Lower values also catch edits and crops, with more false matches.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Large Files") {
                Picker("Default threshold", selection: $settings.largeFileThresholdMB) {
                    ForEach([10, 25, 50, 100, 250, 500, 1000], id: \.self) { Text("\($0) MB").tag($0) }
                }
            }
            Section("Old Media") {
                Picker("Default age", selection: $settings.oldMediaThreshold) {
                    ForEach(OldMediaThreshold.allCases) { Text("Older than \($0.title)").tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct DataSettingsPane: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AnalysisStore.self) private var analysis
    @Environment(DeletionStore.self) private var deletion
    @Environment(\.thumbnailService) private var thumbnails
    @State private var cacheSize: Int64 = 0
    @State private var confirmation: Confirmation?

    enum Confirmation: String, Identifiable {
        case cache, index, scans, deletions
        var id: String { rawValue }
    }

    var body: some View {
        Form {
            Section("Thumbnail Cache") {
                LabeledContent("Size on disk", value: cacheSize.formattedBytes)
                Button("Clear Thumbnail Cache…") { confirmation = .cache }
            }
            Section("Media Index") {
                LabeledContent("Indexed items", value: library.items.count.formatted())
                Button("Clear Index…") { confirmation = .index }
                    .disabled(library.isScanning)
            }
            Section("Scan History") {
                ForEach(library.scanSessions.prefix(6)) { session in
                    HStack {
                        Image(systemName: session.wasCancelled ? "stop.circle" : "checkmark.circle")
                            .foregroundStyle(session.wasCancelled ? Palette.warning : Palette.success)
                        Text(session.finishedAt.mediumDisplay)
                        Spacer()
                        Text(session.wasCancelled ? "Cancelled" : "\(session.mediaCount.formatted()) items · \(session.duration.formattedDuration)")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
                Button("Clear Scan History…") { confirmation = .scans }
                    .disabled(library.scanSessions.isEmpty)
            }
            Section("Deletion History") {
                LabeledContent("Records", value: deletion.history.count.formatted())
                Button("Clear Deletion History…") { confirmation = .deletions }
                    .disabled(deletion.history.isEmpty)
            }
        }
        .formStyle(.grouped)
        .task { await refreshCacheSize() }
        .confirmationDialog(title, isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), presenting: confirmation) { item in
            Button("Clear", role: .destructive) { Task { await perform(item) } }
        } message: { _ in
            Text("This only affects CleanLocal’s own data. Your media files are never touched.")
        }
    }

    private var title: String {
        switch confirmation {
        case .cache: "Clear the thumbnail cache?"
        case .index: "Clear the media index? You’ll need to scan again."
        case .scans: "Clear scan history?"
        case .deletions: "Clear deletion history?"
        case nil: ""
        }
    }

    private func perform(_ item: Confirmation) async {
        switch item {
        case .cache:
            try? thumbnails?.clearCaches()
            await refreshCacheSize()
        case .index:
            analysis.reset()
            await library.clearIndex()
        case .scans:
            await library.clearScanHistory()
        case .deletions:
            deletion.clearHistory()
        }
    }

    private func refreshCacheSize() async {
        guard let thumbnails else { return }
        cacheSize = await Task.detached { thumbnails.diskCacheSize() }.value
    }
}

private struct PrivacySettingsPane: View {
    var body: some View {
        Form {
            Section {
                privacyRow("wifi.slash", "No network access", "CleanLocal has no network entitlement. It can’t upload, sync or phone home.")
                privacyRow("cpu", "Everything on-device", "Scanning, hashing, similarity detection and thumbnails all run locally.")
                privacyRow("chart.bar.xaxis", "No analytics or tracking", "There is no telemetry, crash reporting service or advertising SDK.")
                privacyRow("folder.badge.person.crop", "Only what you allow", "The App Sandbox limits CleanLocal to folders you choose and, if you allow it, your Photos library via Apple’s PhotoKit.")
                privacyRow("trash.slash", "Nothing removed automatically", "Every removal needs your confirmation and goes to the Trash or Photos’ Recently Deleted, never erased outright.")
            } header: {
                Text("Your Privacy")
            }
            Section("Data CleanLocal stores") {
                Text("A metadata index (file names, sizes, dates, dimensions and content fingerprints), small thumbnail images, your preferences and an activity log — all inside CleanLocal’s private container on this Mac. Clear any of it under Data & Cache.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func privacyRow(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            Image(systemName: symbol).foregroundStyle(Palette.brandTeal).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct AboutPane: View {
    var body: some View {
        VStack(spacing: Spacing.l) {
            BrandMark(size: 96)
            VStack(spacing: Spacing.xs) {
                Text(AppConstants.appName).font(.heroTitle)
                Text(AppConstants.tagline).font(.title3).foregroundStyle(Palette.brandGradient)
                Text("Version \(AppConstants.version)").font(.callout).foregroundStyle(.secondary)
            }
            Text("A native macOS utility for finding and safely removing unneeded photos and videos. Built with SwiftUI, PhotoKit, AVFoundation, ImageIO and CryptoKit.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
        }
        .padding(Spacing.xxxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
